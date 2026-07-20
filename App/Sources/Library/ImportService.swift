import Foundation

struct ImportOutcome: Equatable {
    var imported: [String] = []
    var duplicates: [String] = []
    var rejected: [String: String] = [:]

    /// Folds a per-candidate outcome into this aggregate. `imported` and
    /// `duplicates` simply append — every entry there already names a
    /// distinct stored file. `rejected` is keyed by the candidate's own
    /// filename, so two independent candidates (e.g. two different zips)
    /// can each reject an entry under the identical basename; both
    /// LibraryView.summary(of:) and ImportNotices.summary(of:quarantines:)
    /// read `rejected` (the former lists every key/value to the user, the
    /// latter just counts them), so silently overwriting on collision would
    /// both hide one file's reason and undercount "N failed" — uniquify the
    /// same way moveToImportFailed already does for on-disk name clashes.
    mutating func merge(_ other: ImportOutcome) {
        imported += other.imported
        duplicates += other.duplicates
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
/// deliberately tiny (String/String payloads only) so it crosses the
/// Task.detached boundary without any Sendable ceremony.
private enum WADCandidateResult {
    case rejected(String)
    case ready(kind: String, family: String, sha1: String)
}

@MainActor
final class ImportService {
    private let library: LibraryService
    private let store: WADStore

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

    init(library: LibraryService, store: WADStore) {
        self.library = library
        self.store = store
    }

    /// Imports picker/Files-app URLs: .wad validated+classified, .deh/.bex
    /// taken by extension, .zip recursed into. Security-scoped access is
    /// handled here so callers can pass fileImporter URLs directly.
    ///
    /// Stays synchronous: this is the user-initiated picker flow (the user
    /// is already looking at a progress-less system picker sheet), unlike
    /// adoptLooseFiles() below which runs unattended on launch and must not
    /// block the first frame.
    func importFiles(at urls: [URL]) -> ImportOutcome {
        var outcome = ImportOutcome()
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            importOne(url: url, into: &outcome)
        }
        return outcome
    }

    /// Adopts files users dropped into Documents via the Files app
    /// (UIFileSharingEnabled exposes it), plus files iOS copied into
    /// Documents/Inbox/ for a non-in-place "Open in WADdle" share/open.
    /// Call on launch/foreground.
    ///
    /// Runs off the launch path: hashing and copying (the expensive parts —
    /// a loose WAD can be hundreds of MB) happen on detached background
    /// tasks, with only the SwiftData lookups/writes hopping back to the
    /// MainActor. Candidates are still processed one at a time (not
    /// fanned out concurrently): each candidate's store write would also
    /// contend on the same store directory's collision-suffix scan.
    func adoptLooseFiles() async -> ImportOutcome {
        var outcome = ImportOutcome()
        let docs = URL.documentsDirectory
        var candidates = looseFiles(in: docs)
        let inbox = docs.appendingPathComponent("Inbox", isDirectory: true)
        if FileManager.default.fileExists(atPath: inbox.path) {
            candidates += looseFiles(in: inbox)
        }
        for url in candidates {
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
            await importOneAsync(url: url, into: &local)
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
        return outcome
    }

    private func looseFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])) ?? [])
            .filter { ["wad", "deh", "bex", "zip"].contains($0.pathExtension.lowercased()) }
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

    // MARK: Synchronous path (importFiles/picker flow)

    private func importOne(url: URL, into outcome: inout ImportOutcome) {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "zip":
            do {
                let extraction = try ZipExtractor.extractGameFiles(from: url, maxEntryBytes: maxZipEntryBytes)
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
                        outcome.rejected[name] = "No WAD or DEH files inside the zip."
                    }
                    return
                }
                for file in extraction.files {
                    importOne(url: file.url, into: &outcome)
                }
            } catch {
                outcome.rejected[name] = "Could not read zip archive."
            }
        case "deh", "bex":
            guard let data = try? Data(contentsOf: url) else {
                outcome.rejected[name] = "File could not be read."
                return
            }
            storeAndRegister(url: url, name: name, kind: WADKind.deh.rawValue,
                             family: GameFamily.unknown.rawValue,
                             sha1: WADStore.sha1(of: data), into: &outcome)
        case "wad":
            do {
                guard let data = try? Data(contentsOf: url) else {
                    outcome.rejected[name] = "File could not be read."
                    return
                }
                let parsed = try WADParser.parse(data)
                storeAndRegister(url: url, name: name, kind: parsed.kind.rawValue,
                                 family: WADParser.gameFamily(of: parsed.lumpNames).rawValue,
                                 sha1: WADStore.sha1(of: data), into: &outcome)
            } catch WADParseError.badMagic {
                outcome.rejected[name] = "Not a WAD file (bad header magic)."
            } catch WADParseError.tooSmall {
                outcome.rejected[name] = "File is truncated (smaller than a WAD header)."
            } catch {
                outcome.rejected[name] = "WAD directory is corrupt."
            }
        default:
            outcome.rejected[name] = "Unsupported file type."
        }
    }

    private func storeAndRegister(url: URL, name: String, kind: String, family: String,
                                  sha1: String, into outcome: inout ImportOutcome) {
        // Check the library's sha1 index before touching the store: it's a
        // single lookup, versus WADStore.store's on-disk rescan (reads and
        // hashes every stored file) to do the same dedupe check.
        if let existing = try? library.findWAD(sha1: sha1) {
            if existing.isBundled ||
               FileManager.default.fileExists(atPath: library.fileURL(for: existing).path) {
                outcome.duplicates.append((name as NSString).deletingPathExtension)
                return
            }
            // The DB row is legit but its backing file vanished from disk
            // (deleted out-of-band) — restore it under a fresh store
            // filename and repoint the row, rather than reporting a
            // duplicate that doesn't actually exist anywhere.
            do {
                let stored = try store.store(fileAt: url, preferredName: name, precomputedSHA1: sha1)
                try library.repairFilename(of: existing, to: stored.filename)
                outcome.imported.append((stored.filename as NSString).deletingPathExtension)
            } catch {
                outcome.rejected[name] = "Could not copy file into the library."
            }
            return
        }
        do {
            let stored = try store.store(fileAt: url, preferredName: name, precomputedSHA1: sha1)
            try library.registerImported(filename: stored.filename, sha1: stored.sha1,
                                         kind: kind, family: family)
            outcome.imported.append((stored.filename as NSString).deletingPathExtension)
        } catch {
            outcome.rejected[name] = "Could not copy file into the library."
        }
    }

    // MARK: Async path (adoptLooseFiles/launch flow)

    private func importOneAsync(url: URL, into outcome: inout ImportOutcome) async {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "zip":
            // Extraction itself stays on Main (not in scope here — none of
            // the provisioned/real-world fixtures that gate this task are
            // zips, and the brief scopes the off-main move to hashing and
            // copying); only the per-entry hash+store work below is async.
            do {
                let extraction = try ZipExtractor.extractGameFiles(from: url, maxEntryBytes: maxZipEntryBytes)
                defer { try? FileManager.default.removeItem(at: extraction.dir) }
                // See the sync path above: record every oversize entry
                // unconditionally so a partially-valid zip doesn't lose all
                // trace of what it dropped.
                for oversizeName in extraction.skippedOversize {
                    outcome.rejected[oversizeName] = oversizeRejectionReason
                }
                if extraction.files.isEmpty {
                    if extraction.skippedOversize.isEmpty {
                        outcome.rejected[name] = "No WAD or DEH files inside the zip."
                    }
                    return
                }
                for file in extraction.files {
                    await importOneAsync(url: file.url, into: &outcome)
                }
            } catch {
                outcome.rejected[name] = "Could not read zip archive."
            }
        case "deh", "bex":
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
                                        family: GameFamily.unknown.rawValue, sha1: sha1, into: &outcome)
        case "wad":
            // WADParser.parse needs the whole file loaded (it slices into
            // the lump directory by offset), so there's no avoiding a full
            // Data(contentsOf:) read here — but it, the parse, and the hash
            // all happen inside this detached task, off Main. Hashing from
            // the buffer we already loaded for parsing (rather than a
            // second streamed pass over the file) avoids reading a 293MB
            // WAD like Eviternity II off disk twice.
            let result = await Task.detached { () -> WADCandidateResult in
                guard let data = try? Data(contentsOf: url) else {
                    return .rejected("File could not be read.")
                }
                do {
                    let parsed = try WADParser.parse(data)
                    return .ready(kind: parsed.kind.rawValue,
                                 family: WADParser.gameFamily(of: parsed.lumpNames).rawValue,
                                 sha1: WADStore.sha1(of: data))
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
            case .ready(let kind, let family, let sha1):
                await storeAndRegisterAsync(url: url, name: name, kind: kind, family: family,
                                            sha1: sha1, into: &outcome)
            }
        default:
            outcome.rejected[name] = "Unsupported file type."
        }
    }

    private func storeAndRegisterAsync(url: URL, name: String, kind: String, family: String,
                                       sha1: String, into outcome: inout ImportOutcome) async {
        // Same hash-first dedupe as the sync path: a single indexed DB
        // lookup on Main, before ever touching the (potentially huge) file
        // again for a copy.
        if let existing = try? library.findWAD(sha1: sha1) {
            if existing.isBundled ||
               FileManager.default.fileExists(atPath: library.fileURL(for: existing).path) {
                outcome.duplicates.append((name as NSString).deletingPathExtension)
                return
            }
            do {
                let stored = try await copyIntoStore(url: url, name: name, sha1: sha1)
                try library.repairFilename(of: existing, to: stored.filename)
                outcome.imported.append((stored.filename as NSString).deletingPathExtension)
            } catch {
                outcome.rejected[name] = "Could not copy file into the library."
            }
            return
        }
        do {
            let stored = try await copyIntoStore(url: url, name: name, sha1: sha1)
            try library.registerImported(filename: stored.filename, sha1: stored.sha1,
                                         kind: kind, family: family)
            outcome.imported.append((stored.filename as NSString).deletingPathExtension)
        } catch {
            outcome.rejected[name] = "Could not copy file into the library."
        }
    }

    /// The actual disk copy, off-main. WADStore is a value type with no
    /// shared state, so a local copy of it is safe to hand into a detached
    /// task (capturing `self`, the MainActor-isolated ImportService,
    /// wouldn't be).
    private func copyIntoStore(url: URL, name: String, sha1: String) async throws -> StoredWAD {
        let store = self.store
        return try await Task.detached {
            try store.store(fileAt: url, preferredName: name, precomputedSHA1: sha1)
        }.value
    }
}
