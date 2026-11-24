import Foundation
import ZIPFoundation

struct ExtractedFile {
    let name: String
    let url: URL
}

enum ZipExtractor {
    /// What gets extracted; the rest of the archive is ignored.
    private static let gameExtensions = ImportFileType.zipMemberExtensions

    /// Zip entries larger than this are skipped rather than extracted, so a
    /// hostile or merely absurd archive can't blow past the store's disk
    /// budget in one import.
    static let maxEntryBytes: Int64 = 512 * 1024 * 1024

    /// An archive whose game files add up to more than this is refused
    /// whole (#516): the per-entry cap alone let a 16 MB zip of 32 entries
    /// just under it unpack to 16 GiB. Twice `maxEntryBytes`, so any single
    /// file the app takes still fits, with room for its patches.
    static let maxTotalBytes: Int64 = 1024 * 1024 * 1024

    /// An archive with more game files (`.wad`, `.deh`, `.bex`) than this is
    /// refused whole. Real WAD zips carry one to five; each one extracted is
    /// a hash, an import and a line of outcome.
    static let maxGameEntries = 64

    /// An archive with more entries of any kind than this is refused whole,
    /// before anything is extracted. Far above any real mod archive.
    static let maxEntries = 10_000

    /// The caps one extraction runs under. `ImportService` builds one from
    /// its injectable seams so tests can use small values.
    struct Limits: Sendable, Equatable {
        var entryBytes: Int64 = ZipExtractor.maxEntryBytes
        var totalBytes: Int64 = ZipExtractor.maxTotalBytes
        var gameEntries: Int = ZipExtractor.maxGameEntries
        var entries: Int = ZipExtractor.maxEntries
    }

    /// Why a whole archive was refused. Nothing it held is extracted or
    /// left behind.
    enum Refusal: Error, Equatable {
        /// Its game files add up to more than the total cap, by their
        /// declared sizes or by the bytes they actually unpacked to.
        case tooLarge(limit: Int64)
        /// It holds more game files than the cap.
        case tooManyGameFiles(limit: Int)
        /// It holds more entries of any kind than the cap.
        case tooManyEntries(limit: Int)
        /// An entry unpacked to more bytes than its header declared.
        case sizeMismatch
        /// Recognised as a zip only by its content and laid out like a pk3.
        case pk3Layout

        /// The reason recorded for the archive, said to the player.
        var reason: String {
            switch self {
            case .tooLarge(let limit):
                return "This zip unpacks to more than \(ZipExtractor.describe(bytes: limit)), the import limit."
            case .tooManyGameFiles(let limit):
                return "This zip holds more than \(limit) WAD and DEH files, the import limit."
            case .tooManyEntries(let limit):
                return "This zip holds more than \(limit) files, the import limit."
            case .sizeMismatch:
                return "This zip is damaged: a file inside it is larger than the zip says."
            case .pk3Layout:
                return ImportFileType.refusedReason
            }
        }
    }

    /// "1 GB", "1 MB", or a plain byte count for a cap that is neither.
    static func describe(bytes: Int64) -> String {
        let mib: Int64 = 1024 * 1024
        let gib = mib * 1024
        if bytes >= gib, bytes % gib == 0 { return "\(bytes / gib) GB" }
        if bytes >= mib, bytes % mib == 0 { return "\(bytes / mib) MB" }
        return "\(bytes) bytes"
    }

    static func extractGameFiles(from zipURL: URL) throws
        -> (dir: URL, files: [ExtractedFile], skippedOversize: [String]) {
        try extractGameFiles(from: zipURL, limits: Limits())
    }

    static func extractGameFiles(from zipURL: URL, maxEntryBytes: Int64) throws
        -> (dir: URL, files: [ExtractedFile], skippedOversize: [String]) {
        try extractGameFiles(from: zipURL, limits: Limits(entryBytes: maxEntryBytes))
    }

    /// Extracts the archive's game files into a fresh `tmp/wad-import-*`
    /// directory the caller removes. Entries over `limits.entryBytes` are
    /// skipped and named in `skippedOversize`; every other cap refuses the
    /// whole archive with a `Refusal`, and then nothing is left behind.
    ///
    /// `refusingPK3Layout` is for an archive recognised as a zip only by its
    /// content: one laid out like a pk3 is refused, since unpacking just its
    /// WADs would import a map set without the rest of the mod.
    static func extractGameFiles(from zipURL: URL, limits: Limits,
                                 refusingPK3Layout: Bool = false) throws
        -> (dir: URL, files: [ExtractedFile], skippedOversize: [String]) {
        // A negative cap would otherwise first surface as a UInt64
        // conversion trap deep in the entry loop below.
        precondition(limits.entryBytes >= 0 && limits.totalBytes >= 0
                     && limits.gameEntries >= 0 && limits.entries >= 0,
                     "caps must be non-negative")
        let archive = try Archive(url: zipURL, accessMode: .read)

        // Everything that can be decided from the central directory is
        // decided before anything is written.
        var entryCount = 0
        var gameEntryCount = 0
        var declaredTotal: UInt64 = 0
        var looksLikePK3 = false
        for entry in archive {
            entryCount += 1
            guard entryCount <= limits.entries else {
                throw Refusal.tooManyEntries(limit: limits.entries)
            }
            if refusingPK3Layout, isPK3Marker(entry.path) { looksLikePK3 = true }
            guard entry.type == .file, isGameFile(entry.path) else { continue }
            gameEntryCount += 1
            // An oversize entry is skipped, not extracted, so it spends
            // nothing of the total.
            if entry.uncompressedSize <= UInt64(limits.entryBytes) {
                declaredTotal += entry.uncompressedSize
            }
        }
        if looksLikePK3 { throw Refusal.pk3Layout }
        if gameEntryCount > limits.gameEntries {
            throw Refusal.tooManyGameFiles(limit: limits.gameEntries)
        }
        if declaredTotal > UInt64(limits.totalBytes) {
            throw Refusal.tooLarge(limit: limits.totalBytes)
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wad-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var files: [ExtractedFile] = []
        var usedNames: Set<String> = []
        var skippedOversize: [String] = []
        var writtenTotal: UInt64 = 0

        do {
            for entry in archive where entry.type == .file {
                guard isGameFile(entry.path) else { continue }
                let basename = (entry.path as NSString).lastPathComponent

                guard entry.uncompressedSize <= UInt64(limits.entryBytes) else {
                    skippedOversize.append(basename)
                    continue
                }

                // Uniquify if basename already used
                let uniqueName = uniqueBasename(basename, usedNames: usedNames)
                usedNames.insert(uniqueName)

                let dest = dir.appendingPathComponent(uniqueName)
                try extract(entry, from: archive, to: dest,
                            writtenTotal: &writtenTotal, totalLimit: limits.totalBytes)
                files.append(ExtractedFile(name: uniqueName, url: dest))
            }
            return (dir, files, skippedOversize)
        } catch {
            // Clean up temp dir on extraction failure
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    /// Writes `entry` to `dest`, counting the bytes it really unpacks to:
    /// a header can lie, and ZIPFoundation inflates a deflated entry until
    /// its compressed bytes run out, whatever size the header declared.
    private static func extract(_ entry: Entry, from archive: Archive, to dest: URL,
                                writtenTotal: inout UInt64, totalLimit: Int64) throws {
        guard FileManager.default.createFile(atPath: dest.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: dest.path])
        }
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        let declared = entry.uncompressedSize
        var written: UInt64 = 0
        var total = writtenTotal
        _ = try archive.extract(entry) { chunk in
            let count = UInt64(chunk.count)
            guard written + count <= declared else { throw Refusal.sizeMismatch }
            guard total + count <= UInt64(totalLimit) else {
                throw Refusal.tooLarge(limit: totalLimit)
            }
            try handle.write(contentsOf: chunk)
            written += count
            total += count
        }
        writtenTotal = total
    }

    private static func isGameFile(_ path: String) -> Bool {
        let ext = ((path as NSString).lastPathComponent as NSString).pathExtension.lowercased()
        return gameExtensions.contains(ext)
    }

    /// Lumps a pk3 keeps at its root, matched by name with any extension.
    private static let pk3RootLumps: Set<String> = ["DECORATE", "ZSCRIPT", "GAMEINFO", "MAPINFO", "ZMAPINFO"]
    /// Folders a pk3 keeps at its root.
    private static let pk3RootFolders: Set<String> = ["maps", "sprites", "textures", "sounds", "graphics"]

    /// Whether an entry at `path` is one only a pk3 has: a root
    /// `DECORATE`, `ZSCRIPT`, `GAMEINFO`, `MAPINFO` or `ZMAPINFO`, or
    /// anything in (or the entry for) a top-level `maps/`, `sprites/`,
    /// `textures/`, `sounds/` or `graphics/` folder.
    static func isPK3Marker(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let first = components.first else { return false }
        if components.count == 1, !path.hasSuffix("/") {
            let stem = (String(first) as NSString).deletingPathExtension.uppercased()
            return pk3RootLumps.contains(stem)
        }
        return pk3RootFolders.contains(first.lowercased())
    }

    private static func uniqueBasename(_ basename: String, usedNames: Set<String>) -> String {
        guard usedNames.contains(basename) else { return basename }

        let nameWithoutExt = (basename as NSString).deletingPathExtension
        let ext = (basename as NSString).pathExtension

        var counter = 2
        while true {
            let candidate = ext.isEmpty ? "\(nameWithoutExt) (\(counter))" : "\(nameWithoutExt) (\(counter)).\(ext)"
            if !usedNames.contains(candidate) { return candidate }
            counter += 1
        }
    }
}
