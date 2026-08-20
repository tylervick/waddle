import Foundation
import MetricKit

/// Persists MetricKit payloads (diagnostics: crashes, hangs, disk-write
/// exceptions; metrics: launch time, memory, hangs, CPU) as raw JSON files.
/// No processing, no symbolication, and -- per the privacy policy --
/// absolutely no upload: files sit here until the user exports them or
/// retention prunes them.
///
/// One store owns one directory and one filename prefix, and prunes only what
/// it can enumerate there. `metrics(in:)` below builds the metric-payload
/// store on that property; see `DiagnosticsPaths.metricsDirectory(in:)` for
/// why the two kinds must not share a retention pool.
final class DiagnosticsStore {
    /// Diagnostic payloads. Kept as-is: files already on disk carry it.
    static let diagnosticPrefix = "metrickit-"
    /// Metric payloads. Deliberately not a `metrickit-`-derived name -- the
    /// export flattens every bundled file into one directory, and a reader
    /// opening the zip should be able to tell a crash report from a day of
    /// routine telemetry by its name alone.
    static let metricPrefix = "mxmetric-"

    let directory: URL
    let maxPayloads: Int
    let filePrefix: String

    init(directory: URL, maxPayloads: Int = 10,
         filePrefix: String = DiagnosticsStore.diagnosticPrefix) {
        self.directory = directory
        self.maxPayloads = maxPayloads
        self.filePrefix = filePrefix
    }

    /// The metric-payload store for a diagnostics directory: its own
    /// subdirectory, its own prefix, and its own retention count.
    ///
    /// 30 rather than the diagnostics default of 10 because the cadences
    /// differ by orders of magnitude -- MetricKit delivers metrics about once
    /// a day, so 30 is roughly a month of history, where 10 would be a week
    /// and a half. Diagnostics stay at 10 because they arrive only when
    /// something goes wrong and each one is worth far more.
    static func metrics(in diagnosticsDirectory: URL,
                        maxPayloads: Int = 30) -> DiagnosticsStore {
        DiagnosticsStore(directory: DiagnosticsPaths.metricsDirectory(in: diagnosticsDirectory),
                         maxPayloads: maxPayloads,
                         filePrefix: metricPrefix)
    }

    /// One prefix's `*.json` in one directory, sorted oldest-first -- diagnostic
    /// payloads by default, since those are what every existing caller wants.
    /// The timestamp is embedded in the name, so lexical order IS chronological
    /// order.
    static func payloadFiles(in directory: URL,
                             prefix: String = DiagnosticsStore.diagnosticPrefix) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix(prefix)
                   && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// `mxmetric-*.json` from the metrics subdirectory of a diagnostics
    /// directory, oldest-first. Callers hold the diagnostics directory, not
    /// the metrics one, so the subdirectory hop lives here.
    static func metricPayloadFiles(in diagnosticsDirectory: URL) -> [URL] {
        payloadFiles(in: DiagnosticsPaths.metricsDirectory(in: diagnosticsDirectory),
                     prefix: metricPrefix)
    }

    @discardableResult
    func savePayloadData(_ data: Data, receivedAt date: Date) throws -> URL {
        try DiagnosticsPaths.ensureExcludedDirectory(directory)
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        // UUID suffix: several payloads can arrive in one delivery batch with
        // the same receipt date, and each must land in its own file.
        let name = "\(filePrefix)\(stamp)-\(UUID().uuidString.prefix(8)).json"
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)

        // Scoped to this store's own prefix and directory, so pruning one kind
        // of payload can never reach the other.
        let files = Self.payloadFiles(in: directory, prefix: filePrefix)
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
///
/// `MXMetricManagerSubscriber`'s two callbacks are both optional, so a missing
/// one is silent: the app subscribes, payloads arrive, and nothing happens.
/// Both are implemented here for that reason.
final class DiagnosticsMetricSubscriber: NSObject, MXMetricManagerSubscriber {
    nonisolated(unsafe) static let shared = DiagnosticsMetricSubscriber(
        directory: DiagnosticsPaths.directory)

    private let diagnostics: DiagnosticsStore
    private let metrics: DiagnosticsStore

    init(diagnostics: DiagnosticsStore, metrics: DiagnosticsStore) {
        self.diagnostics = diagnostics
        self.metrics = metrics
    }

    /// Both stores derived from one diagnostics directory -- the app's wiring,
    /// and the one tests should use, so nothing can pair them up differently
    /// than the app does.
    convenience init(directory: URL) {
        self.init(diagnostics: DiagnosticsStore(directory: directory),
                  metrics: .metrics(in: directory))
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), into: diagnostics)
        }
    }

    /// Metric payloads: launch time, hang rate, memory, CPU, animation, and
    /// exit reasons, delivered roughly daily from real devices.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), into: metrics)
        }
    }

    private func save(_ data: Data, into store: DiagnosticsStore,
                      receivedAt date: Date = Date()) {
        // Best-effort: a full disk must not turn a crash report into a
        // second crash.
        try? store.savePayloadData(data, receivedAt: date)
    }

    /// The two callbacks' bodies, reachable from tests: neither
    /// `MXDiagnosticPayload` nor `MXMetricPayload` has a public initializer,
    /// so raw `Data` through these is the only way to drive the real routing.
    /// Each names the store its callback uses and nothing else, so a test
    /// cannot exercise a routing this class does not actually perform.
    func saveDiagnosticPayloadData(_ data: Data, receivedAt date: Date = Date()) {
        save(data, into: diagnostics, receivedAt: date)
    }

    func saveMetricPayloadData(_ data: Data, receivedAt date: Date = Date()) {
        save(data, into: metrics, receivedAt: date)
    }
}
