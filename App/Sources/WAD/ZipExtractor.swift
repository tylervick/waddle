import Foundation
import ZIPFoundation

struct ExtractedFile {
    let name: String
    let url: URL
}

enum ZipExtractor {
    private static let gameExtensions: Set<String> = ["wad", "deh", "bex"]

    static func extractGameFiles(from zipURL: URL) throws -> (dir: URL, files: [ExtractedFile]) {
        let archive = try Archive(url: zipURL, accessMode: .read)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wad-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var files: [ExtractedFile] = []
        var usedNames: Set<String> = []

        do {
            for entry in archive where entry.type == .file {
                let basename = (entry.path as NSString).lastPathComponent
                let ext = (basename as NSString).pathExtension.lowercased()
                guard gameExtensions.contains(ext) else { continue }

                // Uniquify if basename already used
                let uniqueName = uniqueBasename(basename, usedNames: usedNames)
                usedNames.insert(uniqueName)

                let dest = dir.appendingPathComponent(uniqueName)
                _ = try archive.extract(entry, to: dest)
                files.append(ExtractedFile(name: uniqueName, url: dest))
            }
            return (dir, files)
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
