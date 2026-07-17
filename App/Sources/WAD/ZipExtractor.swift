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
        for entry in archive where entry.type == .file {
            let basename = (entry.path as NSString).lastPathComponent
            let ext = (basename as NSString).pathExtension.lowercased()
            guard gameExtensions.contains(ext) else { continue }
            let dest = dir.appendingPathComponent(basename)
            _ = try archive.extract(entry, to: dest)
            files.append(ExtractedFile(name: basename, url: dest))
        }
        return (dir, files)
    }
}
