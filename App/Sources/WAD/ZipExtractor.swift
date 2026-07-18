import Foundation
import ZIPFoundation

struct ExtractedFile {
    let name: String
    let url: URL
}

enum ZipExtractor {
    private static let gameExtensions: Set<String> = ["wad", "deh", "bex"]

    /// Zip entries larger than this are skipped rather than extracted, so a
    /// hostile or merely absurd archive can't blow past the store's disk
    /// budget in one import.
    static let maxEntryBytes: Int64 = 512 * 1024 * 1024

    static func extractGameFiles(from zipURL: URL) throws
        -> (dir: URL, files: [ExtractedFile], skippedOversize: [String]) {
        try extractGameFiles(from: zipURL, maxEntryBytes: maxEntryBytes)
    }

    static func extractGameFiles(from zipURL: URL, maxEntryBytes: Int64) throws
        -> (dir: URL, files: [ExtractedFile], skippedOversize: [String]) {
        // A negative cap would otherwise first surface as a UInt64
        // conversion trap deep in the entry loop below.
        precondition(maxEntryBytes >= 0, "cap must be non-negative")
        let archive = try Archive(url: zipURL, accessMode: .read)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wad-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var files: [ExtractedFile] = []
        var usedNames: Set<String> = []
        var skippedOversize: [String] = []

        do {
            for entry in archive where entry.type == .file {
                let basename = (entry.path as NSString).lastPathComponent
                let ext = (basename as NSString).pathExtension.lowercased()
                guard gameExtensions.contains(ext) else { continue }

                guard entry.uncompressedSize <= UInt64(maxEntryBytes) else {
                    skippedOversize.append(basename)
                    continue
                }

                // Uniquify if basename already used
                let uniqueName = uniqueBasename(basename, usedNames: usedNames)
                usedNames.insert(uniqueName)

                let dest = dir.appendingPathComponent(uniqueName)
                _ = try archive.extract(entry, to: dest)
                files.append(ExtractedFile(name: uniqueName, url: dest))
            }
            return (dir, files, skippedOversize)
        } catch {
            // Clean up temp dir on extraction failure
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
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
