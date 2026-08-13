import Foundation
import MetricKit

/// Persists MetricKit diagnostic payloads (crashes, hangs, disk-write
/// exceptions) as raw JSON files. No processing, no symbolication, and --
/// per the privacy policy -- absolutely no upload: files sit here until the
/// user exports them or retention prunes them.
final class DiagnosticsStore {
    let directory: URL
    let maxPayloads: Int

    init(directory: URL, maxPayloads: Int = 10) {
        self.directory = directory
        self.maxPayloads = maxPayloads
    }

    /// `metrickit-*.json` sorted oldest-first. The timestamp is embedded in
    /// the name, so lexical order IS chronological order.
    static func payloadFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("metrickit-")
                   && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @discardableResult
    func savePayloadData(_ data: Data, receivedAt date: Date) throws -> URL {
        try DiagnosticsPaths.ensureExcludedDirectory(directory)
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        // UUID suffix: several payloads can arrive in one delivery batch with
        // the same receipt date, and each must land in its own file.
        let name = "metrickit-\(stamp)-\(UUID().uuidString.prefix(8)).json"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)

        let files = Self.payloadFiles(in: directory)
        if files.count > maxPayloads {
            for old in files.prefix(files.count - maxPayloads) {
                try? FileManager.default.removeItem(at: old)
            }
        }
        return url
    }
}

/// The app's one MetricKit subscriber. MXMetricManager holds subscribers
/// weakly, so the static `shared` reference is what keeps it alive.
final class DiagnosticsMetricSubscriber: NSObject, MXMetricManagerSubscriber {
    nonisolated(unsafe) static let shared = DiagnosticsMetricSubscriber(
        store: DiagnosticsStore(directory: DiagnosticsPaths.directory))

    private let store: DiagnosticsStore

    init(store: DiagnosticsStore) {
        self.store = store
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            // Best-effort: a full disk must not turn a crash report into a
            // second crash.
            try? store.savePayloadData(payload.jsonRepresentation(),
                                       receivedAt: Date())
        }
    }
}
