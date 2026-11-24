import Foundation

struct ImportOutcome: Equatable {
    var imported: [String] = []
    var duplicates: [String] = []
    var rejected: [String: String] = [:]
    /// Names registered as a base game (an IWAD, or a map set paired to one) —
    /// spec §3.5's "Added" outcome. Subsets of `imported`.
    var games: [String] = []
    /// Names registered as an add-on (never a game). Subset of `imported`.
    var addOns: [String] = []
    /// Names registered as a map set with no base of its family yet. Subset
    /// of `imported`.
    var unpaired: [String] = []

    /// Folds a per-candidate outcome into this aggregate. `imported` and
    /// `duplicates` simply append — every entry there already names a
    /// distinct stored file. `rejected` is keyed by the candidate's own
    /// filename, so two independent candidates (e.g. two different zips)
    /// can each reject an entry under the identical basename;
    /// `ImportNotices.summary(of:quarantines:)` counts `rejected` for its
    /// "N failed" banner, so silently overwriting on collision would
    /// undercount — uniquify the same way moveToImportFailed already does
    /// for on-disk name clashes.
    mutating func merge(_ other: ImportOutcome) {
        imported += other.imported
        duplicates += other.duplicates
        games += other.games
        addOns += other.addOns
        unpaired += other.unpaired
        for (name, reason) in other.rejected {
            var candidate = name
            var counter = 2
            while rejected[candidate] != nil {
                let base = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                counter += 1
            }
            rejected[candidate] = reason
        }
    }
}

/// Result of the off-main parse+hash step for a candidate .wad, handed back
/// to the MainActor caller to decide rejection vs. store+register. Kept
/// deliberately tiny (Strings and a Bool only) so it crosses the
/// Task.detached boundary without any Sendable ceremony.
private enum WADCandidateResult {
    case rejected(String)
    case ready(kind: String, family: String, sha1: String, hasMaps: Bool)
}

/// The kinds of file the library takes, and the one definition of which
/// extensions name them (#499): the picker's content types
/// (`WADImport.contentTypes`), the adoption scan (`looseFiles(in:)`) and the
/// zip extractor (`ZipExtractor`) all read it from here, so they cannot drift
/// apart.
enum ImportFileType: Sendable, Equatable {
    case wad
    /// A DeHackEd patch, `.deh` or `.bex`. It has no header magic, so it is
    /// only ever recognised by name.
    case dehacked
    case zip

    /// Every accepted extension, lowercased, in the order the picker offers
    /// them.
    static let acceptedExtensions: [String] = ["wad", "deh", "bex", "zip"]

    /// What `ZipExtractor` takes out of a zip: everything but another zip.
    static let zipMemberExtensions: Set<String> =
        Set(acceptedExtensions.filter { ImportFileType(extension: $0) != .zip })

    /// The type an extension names, or nil for one the library does not take.
    init?(extension ext: String) {
        switch ext.lowercased() {
        case "wad": self = .wad
        case "deh", "bex": self = .dehacked
        case "zip": self = .zip
        default: return nil
        }
    }

    /// The type a file's first bytes give away: `IWAD`/`PWAD` for a WAD,
    /// `PK\\x03\\x04` (a local file header) for a zip. Nil when they give
    /// away neither, including a file too short or unreadable.
    init?(sniffing url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return nil }
        switch [UInt8](head) {
        case Array("IWAD".utf8), Array("PWAD".utf8): self = .wad
        case [0x50, 0x4B, 0x03, 0x04]: self = .zip
        default: return nil
        }
    }

    /// The type of the file at `url`, imported under `name`: taken from
    /// `name`'s extension, then from the URL's, and only then from the
    /// content. A name or URL whose extension the library does not take
    /// (a download's "download" or ".tmp") says nothing either way. Nil when
    /// none of the three settles it.
    static func resolve(url: URL, name: String) -> ImportFileType? {
        ImportFileType(extension: (name as NSString).pathExtension)
            ?? ImportFileType(extension: url.pathExtension)
            ?? ImportFileType(sniffing: url)
    }

    /// `name`, with this type's extension added if it does not already carry
    /// one that names this type.
    func naming(_ name: String) -> String {
        if ImportFileType(extension: (name as NSString).pathExtension) == self { return name }
        switch self {
        case .wad: return name + ".wad"
        case .dehacked: return name + ".deh"
        case .zip: return name + ".zip"
        }
    }
}

/// Where a file reached the library from. Decides what the import does
/// besides importing: only adoption owns its files, so only adoption deletes
/// or quarantines them afterwards, and only its notice says so.
enum ImportRoute: Sendable, Equatable {
    /// The system file picker: the toolbar's Add, the welcome card's
    /// **Add Your Games**, and the add-hint tile.
    case picker
    /// "Open in Waddle" and the share sheet (`.onOpenURL`).
    case openIn
    /// Loose files in Documents/ and Documents/Inbox/, swept on launch and
    /// on return to the foreground.
    case adoption

    var quarantinesRejects: Bool { self == .adoption }
}

/// One file for `ImportService.importFiles(_:from:)`. `suggestedFilename`
/// is the name its source gave it (a server's name for a download), used in
/// place of the URL's own, often temporary, name.
struct ImportRequest: Sendable, Equatable {
    var url: URL
    var suggestedFilename: String?

    init(url: URL, suggestedFilename: String? = nil) {
        self.url = url
        self.suggestedFilename = suggestedFilename
    }
}

/// A first-come, first-served turnstile on the MainActor: `enter()` returns
/// once every earlier caller has called `leave()`.
@MainActor
private final class ImportGate {
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

@MainActor
final class ImportService {
    private let library: LibraryService
    private let store: WADStore
    private let notices: ImportNotices
    private let usage: UsageStore
    private let gate = ImportGate()

    /// Injectable seam for tests only: production always relies on
    /// ZipExtractor's own 512 MB default. Internal (not private) so
    /// ImportServiceTests can shrink it to exercise the oversize-rejection
    /// path without shipping a real 512 MB fixture.
    var maxZipEntryBytes: Int64 = ZipExtractor.maxEntryBytes

    /// Reason recorded for every zip entry ZipExtractor skips for being
    /// over the size cap. Shared by both extraction paths and matched by
    /// name in adoptLooseFiles's keep/quarantine/delete decision below.
    /// Derived from the cap actually in effect so the user-facing number
    /// can never drift from the enforced limit.
    private var oversizeRejectionReason: String {
        "Entry exceeds the \(maxZipEntryBytes / (1024 * 1024)) MB import limit."
    }

    /// `notices` and `usage` default to the app's shared ones; tests hand
    /// in their own so an import there neither shows a banner nor counts.
    init(library: LibraryService, store: WADStore,
         notices: ImportNotices? = nil, usage: UsageStore? = nil) {
        self.library = library
        self.store = store
        self.notices = notices ?? .shared
        self.usage = usage ?? .shared
    }

    /// The one way into the library (#499). Every route — the picker, Open
    /// In, loose-file adoption, and whatever source comes next — hands its
    /// files here, and this does the whole sequence after an import:
    /// import, count it (`UsageStore.recordImport`), say what happened
    /// (`ImportNotices`), and tell the shelf and Files to refresh
    /// (`.libraryDidChange`). No call site repeats any of that.
    ///
    /// Parsing, hashing, unzipping and copying all run on detached tasks,
    /// so awaiting this never blocks the main thread; only the SwiftData
    /// lookups and writes hop back to the MainActor.
    ///
    /// Requests are taken one at a time, in order, and stop at the top of
    /// the next request once the calling task is cancelled (`Task.detached`
    /// does not inherit cancellation, so nothing else would stop them). A
    /// request that has started is left to finish, so its store write and
    /// its keep/quarantine/delete decision stay consistent; whatever is left
    /// is picked up by a later call. The outcome so far is still announced.
    @discardableResult
    func importFiles(_ requests: [ImportRequest], from route: ImportRoute) async -> ImportOutcome {
        var outcome = ImportOutcome()
        for request in requests {
            guard !Task.isCancelled else { break }
            await importRequest(request, from: route, into: &outcome)
        }
        usage.recordImport(outcome)
        notices.post(outcome: outcome, quarantines: route.quarantinesRejects)
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        return outcome
    }

    /// One file, optionally with the name its source gave it (a download's
    /// server-supplied filename, say) when the URL's own name is a
    /// temporary one. See `importFiles(_:from:)`.
    @discardableResult
    func importFile(at url: URL, from route: ImportRoute,
                    suggestedFilename: String? = nil) async -> ImportOutcome {
        await importFiles([ImportRequest(url: url, suggestedFilename: suggestedFilename)], from: route)
    }

    /// Several files that carry their own names, as the picker returns them.
    /// See `importFiles(_:from:)`.
    @discardableResult
    func importFiles(at urls: [URL], from route: ImportRoute) async -> ImportOutcome {
        await importFiles(urls.map { ImportRequest(url: $0) }, from: route)
    }

    /// Adopts files users dropped into Documents via the Files app
    /// (UIFileSharingEnabled exposes it), plus files iOS copied into
    /// Documents/Inbox/ for a non-in-place "Open in Waddle" share/open.
    /// Call on launch/foreground. Runs off the launch path: see
    /// `importFiles(_:from:)`.
    @discardableResult
    func adoptLooseFiles() async -> ImportOutcome {
        let docs = URL.documentsDirectory
        var candidates = looseFiles(in: docs)
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        if FileManager.default.fileExists(atPath: inbox.path) {
            candidates += looseFiles(in: inbox)
        }
        return await importFiles(candidates.map { ImportRequest(url: $0) }, from: .adoption)
    }

    private func importRequest(_ request: ImportRequest, from route: ImportRoute,
                               into outcome: inout ImportOutcome) async {
        // One request at a time across every caller, not just within one
        // call: the find-copy-register sequence below awaits in the middle,
        // and two routes importing the same bytes at once (an Open In whose
        // Inbox copy the foreground adoption scan also lists) would both
        // miss the sha1 index and register the file twice.
        await gate.enter()
        defer { gate.leave() }

        let url = request.url
        // Open In hands over Documents/Inbox copies, which the adoption scan
        // also lists. If adoption got there first it imported the file,
        // announced it and removed the original, so there is nothing left
        // to import or to report a failure about.
        if route != .adoption, isAdoptionTerritory(url),
           !FileManager.default.fileExists(atPath: url.path) {
            return
        }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = request.suggestedFilename ?? url.lastPathComponent
        guard route.quarantinesRejects else {
            await importOneAsync(url: url, name: name, into: &outcome)
            return
        }
        // A single candidate (e.g. a zip) can fan out into many inner
        // importOneAsync calls, each recording its own imported/
        // duplicate/rejected entry under its own inner filename — not
        // the candidate's. Give each candidate a fresh LOCAL outcome so
        // the keep/quarantine/delete decision below reads only what
        // THIS candidate contributed. (An earlier version diffed a
        // shared outcome's dictionary keys before/after instead; that
        // broke when two candidates rejected an entry under the exact
        // same basename — e.g. two zips each dropping an oversize
        // "SAME.wad" — because the second candidate's rejection landed
        // on an already-present key and the diff saw nothing "new".)
        var local = ImportOutcome()
        await importOneAsync(url: url, name: name, into: &local)
        if local.rejected.isEmpty {
            // Nothing about this candidate failed (a clean import, a
            // pure duplicate, or both) — the content now lives in the
            // store (or already did); the loose original is redundant.
            try? FileManager.default.removeItem(at: url)
        } else {
            // This candidate contributed at least one rejection — a
            // fully-corrupt file, an empty zip, or a zip that imported
            // something valid alongside an oversize/corrupt entry.
            // Don't destroy a file the user can't explain a failure
            // for; move it somewhere visible/recoverable in the Files
            // app instead, so the scan doesn't re-report it forever.
            // (An oversize entry in particular is legitimate content
            // that only missed the cut on size — deleting the zip
            // would destroy its only surviving copy.)
            moveToImportFailed(url)
        }
        outcome.merge(local)
    }

    /// Documents/ and Documents/Inbox/: the two directories adoptLooseFiles
    /// scans.
    private func isAdoptionTerritory(_ url: URL) -> Bool {
        let docs = URL.documentsDirectory.standardizedFileURL
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        return parent == docs || parent == docs.appendingPathComponent("Inbox", isDirectory: true)
    }

    private func looseFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { ImportFileType(extension: $0.pathExtension) != nil }
    }

    /// Moves a loose file that failed import into Documents/Import Failed/,
    /// uniquifying on name collision the same way WADStore does.
    private func moveToImportFailed(_ url: URL) {
        let failedDir = URL.documentsDirectory.appendingPathComponent("Import Failed", isDirectory: true)
        try? FileManager.default.createDirectory(at: failedDir, withIntermediateDirectories: true)

        let name = url.lastPathComponent
        var candidate = name
        var counter = 2
        while FileManager.default.fileExists(atPath: failedDir.appendingPathComponent(candidate).path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        try? FileManager.default.moveItem(at: url, to: failedDir.appendingPathComponent(candidate))
    }

    /// Which of spec §3.5's three outcomes a freshly registered file is.
    private func categorize(_ wad: WADFile, as name: String, into outcome: inout ImportOutcome) {
        switch wad.role {
        case .base:
            outcome.games.append(name)
        case .mapSet:
            let game = (try? library.gamesUsing(fileID: wad.id))?.first
            if let game, game.baseID == nil { outcome.unpaired.append(name) } else { outcome.games.append(name) }
        case .addOn:
            outcome.addOns.append(name)
        }
    }

    // MARK: The import path

    /// Imports one file under `name` — its own filename, or the one its
    /// source suggested. Dispatches on the type `ImportFileType.resolve`
    /// settles from the name, the URL, then the content.
    private func importOneAsync(url: URL, name: String, into outcome: inout ImportOutcome) async {
        let type = await Task.detached {
            ImportFileType.resolve(url: url, name: name)
        }.value
        guard let type else {
            outcome.rejected[name] = "Unsupported file type."
            return
        }
        switch type {
        case .zip:
            do {
                let cap = maxZipEntryBytes
                let extraction = try await Task.detached {
                    try ZipExtractor.extractGameFiles(from: url, maxEntryBytes: cap)
                }.value
                defer { try? FileManager.default.removeItem(at: extraction.dir) }
                // Record every oversize entry unconditionally — not just
                // when it's the only thing in the zip. A zip that also
                // contains a valid file must not lose all record of the
                // entry it dropped: without this, the adopt path sees a
                // clean import and deletes the zip, destroying the
                // oversized content's only copy.
                for oversizeName in extraction.skippedOversize {
                    outcome.rejected[oversizeName] = oversizeRejectionReason
                }
                if extraction.files.isEmpty {
                    if extraction.skippedOversize.isEmpty {
                        // Only a file that calls itself a zip is reported as
                        // an empty one. Something recognised as a zip by its
                        // header alone and holding no game files (a .docx
                        // handed over through the zip document type, say) is
                        // not a game download at all, so it keeps the
                        // rejection it had before content sniffing.
                        let namedZip = ImportFileType(extension: (name as NSString).pathExtension) == .zip
                            || ImportFileType(extension: url.pathExtension) == .zip
                        outcome.rejected[name] = namedZip
                            ? "No WAD or DEH files inside the zip."
                            : "Unsupported file type."
                    }
                    return
                }
                for file in extraction.files {
                    await importOneAsync(url: file.url, name: file.name, into: &outcome)
                }
            } catch {
                outcome.rejected[name] = "Could not read zip archive."
            }
        case .dehacked:
            // A patch is only ever recognised by name, so if the suggested
            // name does not say .deh/.bex the URL did: keep its extension,
            // which the store, the Files screen and the engine go by.
            let name = ImportFileType(extension: (name as NSString).pathExtension) == .dehacked
                ? name : name + "." + url.pathExtension.lowercased()
            // No parsing needed for these — just a readability check +
            // hash, so there's no reason to load the bytes into memory at
            // all; hash straight off disk via the streamed hasher.
            let sha1: String? = await Task.detached {
                try? WADStore.sha1(ofFileAt: url)
            }.value
            guard let sha1 else {
                outcome.rejected[name] = "File could not be read."
                return
            }
            await storeAndRegisterAsync(url: url, name: name, kind: WADKind.deh.rawValue,
                                        family: GameFamily.unknown.rawValue, sha1: sha1,
                                        hasMaps: false, into: &outcome)
        case .wad:
            // A WAD recognised by its header under a name that does not say
            // so (a download's "download") is stored as a .wad: the store,
            // the Files screen and the engine all go by the extension.
            let name = ImportFileType.wad.naming(name)
            // WADParser.parse addresses the whole file (it slices into the
            // lump directory by offset), but it only ever touches two small
            // ranges: the 12-byte header, then numLumps * 16 bytes at
            // dirOffset. .mappedIfSafe serves that from the page cache
            // instead of holding the file resident — a 293MB WAD like
            // Eviternity II would otherwise be one 293MB allocation, and on
            // iOS that is a jetsam risk, not just a slow read. The parse and
            // the hash still happen inside this detached task, off Main, and
            // hashing from the same mapping we parsed (rather than a second
            // streamed pass) keeps this to a single pass over the file.
            //
            // .mappedIfSafe is a request: Foundation declines where it judges
            // mapping unsafe, and behaviour is then exactly what it was
            // before — the floor is the status quo.
            let result = await Task.detached { () -> WADCandidateResult in
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    return .rejected("File could not be read.")
                }
                do {
                    let parsed = try WADParser.parse(data)
                    let hasMaps = WADParser.mapFormat(of: parsed.lumpNames) != .none
                    return .ready(kind: parsed.kind.rawValue,
                                 family: WADParser.gameFamily(of: parsed.lumpNames).rawValue,
                                 sha1: WADStore.sha1(of: data), hasMaps: hasMaps)
                } catch WADParseError.badMagic {
                    return .rejected("Not a WAD file (bad header magic).")
                } catch WADParseError.tooSmall {
                    return .rejected("File is truncated (smaller than a WAD header).")
                } catch {
                    return .rejected("WAD directory is corrupt.")
                }
            }.value
            switch result {
            case .rejected(let reason):
                outcome.rejected[name] = reason
            case .ready(let kind, let family, let sha1, let hasMaps):
                await storeAndRegisterAsync(url: url, name: name, kind: kind, family: family,
                                            sha1: sha1, hasMaps: hasMaps, into: &outcome)
            }
        }
    }

    private func storeAndRegisterAsync(url: URL, name: String, kind: String, family: String,
                                       sha1: String, hasMaps: Bool,
                                       into outcome: inout ImportOutcome) async {
        // Check the library's sha1 index before touching the store: a single
        // indexed DB lookup on Main, before ever touching the (potentially
        // huge) file again for a copy.
        if let existing = try? library.findWAD(sha1: sha1) {
            if FileManager.default.fileExists(atPath: library.fileURL(for: existing).path) {
                outcome.duplicates.append((name as NSString).deletingPathExtension)
                return
            }
            // The DB row is legit but its backing file vanished from disk
            // (deleted out-of-band, or a bundled file the app no longer
            // ships — issue #503) — restore it under a fresh store filename
            // and repoint the row, under its own id, rather than reporting a
            // duplicate that doesn't actually exist anywhere.
            do {
                let stored = try await copyIntoStore(url: url, name: name, sha1: sha1,
                                                     reserved: library.claimedStoreFilenames(excluding: existing))
                try library.repairFilename(of: existing, to: stored.filename, hasMaps: hasMaps)
                let displayName = (stored.filename as NSString).deletingPathExtension
                outcome.imported.append(displayName)
                // A restored map set never got a tile if it arrived with no
                // game of its own — adopt it now, same as a fresh import.
                if existing.role == .mapSet, (try? library.gamesUsing(fileID: existing.id))?.isEmpty == true {
                    try? library.adoptMapSet(existing)
                }
                categorize(existing, as: displayName, into: &outcome)
            } catch {
                outcome.rejected[name] = "Could not copy file into the library."
            }
            return
        }
        do {
            let stored = try await copyIntoStore(url: url, name: name, sha1: sha1,
                                                 reserved: library.claimedStoreFilenames())
            let wad = try library.registerImported(filename: stored.filename, sha1: stored.sha1,
                                                    kind: kind, family: family, hasMaps: hasMaps)
            let displayName = (stored.filename as NSString).deletingPathExtension
            outcome.imported.append(displayName)
            categorize(wad, as: displayName, into: &outcome)
        } catch {
            outcome.rejected[name] = "Could not copy file into the library."
        }
    }

    /// The actual disk copy, off-main. WADStore is a value type with no
    /// shared state, so a local copy of it is safe to hand into a detached
    /// task (capturing `self`, the MainActor-isolated ImportService,
    /// wouldn't be).
    private func copyIntoStore(url: URL, name: String, sha1: String,
                               reserved: Set<String>) async throws -> StoredWAD {
        let store = self.store
        return try await Task.detached {
            try store.store(fileAt: url, preferredName: name, precomputedSHA1: sha1, reserved: reserved)
        }.value
    }
}
