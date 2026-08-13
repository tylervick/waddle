import XCTest
@testable import WADdle

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
