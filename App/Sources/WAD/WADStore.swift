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

    /// Convenience overload: hashes `source` itself (streamed) since the
    /// caller has no precomputed hash to hand in.
    func store(fileAt source: URL, preferredName: String) throws -> StoredWAD {
        try store(fileAt: source, preferredName: preferredName, precomputedSHA1: nil)
    }

    /// Copies `source` into the store under `preferredName` (uniquified on
    /// name collision). `precomputedSHA1`, when supplied, skips a second
    /// hash of content the caller already hashed (e.g. ImportService's
    /// hash-first dedupe check); otherwise the source is streamed through
    /// `sha1(ofFileAt:)`.
    ///
    /// Does NOT dedupe against existing store contents. Since Plan 2's
    /// hash-first fix, the library's sha1 index (a single indexed DB
    /// lookup) is the dedupe source of truth, checked by the caller before
    /// this is ever invoked for a genuine duplicate. Rescanning and
    /// rehashing every file already on disk here — as this used to do — was
    /// pure redundant I/O on the common path.
    func store(fileAt source: URL, preferredName: String,
              precomputedSHA1: String?) throws -> StoredWAD {
        guard FileManager.default.fileExists(atPath: source.path) else { throw WADStoreError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sha1 = try precomputedSHA1 ?? Self.sha1(ofFileAt: source)

        let preferredName = Self.sanitized(preferredName)

        // Resolve name collisions (same name, different content).
        var candidate = preferredName
        var counter = 2
        while FileManager.default.fileExists(atPath: url(forFilename: candidate).path) {
            let base = (preferredName as NSString).deletingPathExtension
            let ext = (preferredName as NSString).pathExtension
            candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            counter += 1
        }
        try FileManager.default.copyItem(at: source, to: url(forFilename: candidate))
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

    /// Streamed SHA-1 over 1MB chunks — avoids loading the whole file into
    /// memory just to hash it (matters for large WADs; Eviternity II is
    /// ~293MB).
    static func sha1(ofFileAt url: URL) throws -> String {
        // InputStream(url:) doesn't reliably fail to construct/open for a
        // missing file on iOS/Simulator: hasBytesAvailable can read true
        // speculatively and the first read() returns 0 (EOF) rather than -1
        // (error), so the loop below would silently finalize the hash of
        // zero bytes instead of throwing. Check existence up front instead
        // of trusting the stream's own error signaling for this case.
        guard FileManager.default.fileExists(atPath: url.path),
              let stream = InputStream(url: url) else { throw WADStoreError.unreadable }
        stream.open()
        defer { stream.close() }
        var hasher = Insecure.SHA1()
        let bufferSize = 1 << 20
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read < 0 { throw WADStoreError.unreadable }
            if read == 0 { break }
            hasher.update(data: Data(buffer[0..<read]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
