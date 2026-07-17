import CryptoKit
import Foundation

struct StoredWAD: Equatable {
    let filename: String
    let sha1: String
    let isDuplicate: Bool
}

enum WADStoreError: Error, Equatable {
    case unreadable
}

/// Owns the on-disk WAD directory. Knows nothing about SwiftData; the
/// library layer keeps metadata and refers to files by `filename`.
struct WADStore {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    static var `default`: WADStore {
        WADStore(directory: URL.documentsDirectory.appendingPathComponent("WADs", isDirectory: true))
    }

    /// Untrusted names (zip entries, picker files) must never escape the
    /// store directory: keep only the basename and drop path tricks.
    private static func sanitized(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "\0", with: "")
        return (base.isEmpty || base == "." || base == "..") ? "unnamed.wad" : base
    }

    func store(fileAt source: URL, preferredName: String) throws -> StoredWAD {
        guard let data = try? Data(contentsOf: source) else { throw WADStoreError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sha1 = Self.sha1(of: data)

        let preferredName = Self.sanitized(preferredName)

        // Dedupe by content hash against everything already in the store.
        let existing = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in existing {
            if let other = try? Data(contentsOf: url), Self.sha1(of: other) == sha1 {
                return StoredWAD(filename: url.lastPathComponent, sha1: sha1, isDuplicate: true)
            }
        }

        // Resolve name collisions (same name, different content).
        var candidate = preferredName
        var counter = 2
        while FileManager.default.fileExists(atPath: url(forFilename: candidate).path) {
            let base = (preferredName as NSString).deletingPathExtension
            let ext = (preferredName as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        try data.write(to: url(forFilename: candidate))
        return StoredWAD(filename: candidate, sha1: sha1, isDuplicate: false)
    }

    func url(forFilename filename: String) -> URL {
        directory.appendingPathComponent(Self.sanitized(filename))
    }

    func delete(filename: String) throws {
        try FileManager.default.removeItem(at: url(forFilename: filename))
    }

    static func sha1(of data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
