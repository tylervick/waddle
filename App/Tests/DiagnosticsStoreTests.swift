import XCTest
@testable import Waddle

final class DiagnosticsStoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagstore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSavesPayloadDataAsTimestampedJSONFile() throws {
        let store = DiagnosticsStore(directory: tmp)
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let url = try store.savePayloadData(Data("{\"crash\":true}".utf8), receivedAt: date)

        XCTAssertTrue(url.lastPathComponent.hasPrefix("metrickit-"))
        XCTAssertEqual(url.pathExtension, "json")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"crash\":true}")
    }

    func testTwoPayloadsAtTheSameInstantGetDistinctFiles() throws {
        let store = DiagnosticsStore(directory: tmp)
        let date = Date(timeIntervalSince1970: 1_770_000_000)
        let a = try store.savePayloadData(Data("a".utf8), receivedAt: date)
        let b = try store.savePayloadData(Data("b".utf8), receivedAt: date)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(DiagnosticsStore.payloadFiles(in: tmp).count, 2)
    }

    func testRetentionKeepsAtMostMaxPayloads() throws {
        let store = DiagnosticsStore(directory: tmp, maxPayloads: 3)
        for i in 0..<5 {
            try store.savePayloadData(Data("p\(i)".utf8),
                receivedAt: Date(timeIntervalSince1970: Double(1_770_000_000 + i)))
        }
        let files = DiagnosticsStore.payloadFiles(in: tmp)
        XCTAssertEqual(files.count, 3)
        let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertFalse(contents.contains("p0"), "oldest payloads must be pruned")
        XCTAssertTrue(contents.contains("p4"))
    }
}

/// The point of issue #167: MetricKit delivers metric payloads roughly daily
/// and diagnostic payloads only when something goes wrong, so the two must not
/// share a retention pool -- routing both through one store would evict every
/// crash report within about `maxPayloads` days.
final class DiagnosticsMetricPayloadTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagmetric-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Drives the subscriber the way the app wires it -- one directory, both
    /// stores derived from it -- because the routing is what is under test.
    private func makeSubscriber() -> DiagnosticsMetricSubscriber {
        DiagnosticsMetricSubscriber(directory: tmp)
    }

    private func date(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: Double(1_770_000_000 + offset))
    }

    func testMetricPayloadsNeverEvictADiagnosticPayload() throws {
        let subscriber = makeSubscriber()
        subscriber.saveDiagnosticPayloadData(Data("{\"crash\":true}".utf8),
                                             receivedAt: date(0))

        // Comfortably past both retention counts: if the two kinds shared a
        // pool of any size, the crash report above would be long gone.
        for i in 1...60 {
            subscriber.saveMetricPayloadData(Data("{\"metric\":\(i)}".utf8),
                                             receivedAt: date(i))
        }

        let diagnostics = DiagnosticsStore.payloadFiles(in: tmp)
        XCTAssertEqual(diagnostics.count, 1,
            "a day of routine telemetry must never cost a crash report")
        XCTAssertEqual(try String(contentsOf: diagnostics[0], encoding: .utf8),
                       "{\"crash\":true}",
                       "the surviving payload must still be readable, not merely present")
    }

    func testMetricPayloadsArePrunedByTheirOwnRetention() throws {
        let subscriber = makeSubscriber()
        for i in 0..<60 {
            subscriber.saveMetricPayloadData(Data("{\"metric\":\(i)}".utf8),
                                             receivedAt: date(i))
        }

        // The app's real cap, not a test-only one: daily delivery means an
        // unpruned metrics directory would grow for as long as the app is
        // installed.
        let metrics = DiagnosticsStore.metricPayloadFiles(in: tmp)
        XCTAssertEqual(metrics.count, DiagnosticsStore.metrics(in: tmp).maxPayloads)
        let contents = try metrics.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertFalse(contents.contains("{\"metric\":0}"),
            "oldest metric payloads must be pruned")
        XCTAssertTrue(contents.contains("{\"metric\":59}"),
            "the newest metric payload must survive")
    }

    func testMetricRetentionIsSizedForDailyDeliveryNotTheDiagnosticsDefault() {
        XCTAssertGreaterThan(DiagnosticsStore.metrics(in: tmp).maxPayloads,
                             DiagnosticsStore(directory: tmp).maxPayloads,
            "metrics arrive about once a day; diagnostics only on failure")
    }

    func testDiagnosticAndMetricPayloadsLandInSeparateDirectories() {
        let subscriber = makeSubscriber()
        subscriber.saveDiagnosticPayloadData(Data("{}".utf8), receivedAt: date(0))
        subscriber.saveMetricPayloadData(Data("{}".utf8), receivedAt: date(1))

        XCTAssertEqual(DiagnosticsStore.payloadFiles(in: tmp).count, 1)
        XCTAssertEqual(DiagnosticsStore.metricPayloadFiles(in: tmp).count, 1)
        XCTAssertEqual(DiagnosticsStore.payloadFiles(
            in: DiagnosticsPaths.metricsDirectory(in: tmp)).count, 0,
            "no diagnostic payload may be written into the metrics directory")
    }
}
