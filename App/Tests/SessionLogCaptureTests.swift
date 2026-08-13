import XCTest
@testable import WADdle

final class SessionLogCaptureTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Opens a file-backed fd the capture can dup2 over, standing in for
    /// stdout. Returns the fd and the file backing the "original" stream.
    private func makeTargetFD() throws -> (fd: Int32, original: URL) {
        let url = tmp.appendingPathComponent("original-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fd = open(url.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        return (fd, url)
    }

    private func writeAll(_ string: String, to fd: Int32) {
        let bytes = Array(string.utf8)
        bytes.withUnsafeBufferPointer { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                XCTAssertGreaterThan(n, 0)
                offset += n
            }
        }
    }

    func testTeesWritesToBothLogFileAndOriginalDestination() throws {
        let (fd, original) = try makeTargetFD()
        defer { close(fd) }
        let capture = SessionLogCapture(directory: tmp, targetFDs: [fd])

        try capture.begin(name: "t1")
        writeAll("P_SetupLevel: E1M1\n", to: fd)
        capture.end()

        let log = tmp.appendingPathComponent("session-t1.log")
        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logText.contains("P_SetupLevel: E1M1"))
        let originalText = try String(contentsOf: original, encoding: .utf8)
        XCTAssertTrue(originalText.contains("P_SetupLevel: E1M1"),
                      "pass-through to the original destination must keep working")
    }

    func testEndRestoresTheOriginalDescriptor() throws {
        let (fd, original) = try makeTargetFD()
        defer { close(fd) }
        let capture = SessionLogCapture(directory: tmp, targetFDs: [fd])

        try capture.begin(name: "t2")
        capture.end()
        writeAll("after-end\n", to: fd)

        let logText = try String(contentsOf: tmp.appendingPathComponent("session-t2.log"),
                                 encoding: .utf8)
        XCTAssertFalse(logText.contains("after-end"),
                       "writes after end() must not reach the log")
        let originalText = try String(contentsOf: original, encoding: .utf8)
        XCTAssertTrue(originalText.contains("after-end"))
    }

    func testLogFileStopsAtByteCapButPassThroughContinues() throws {
        let (fd, original) = try makeTargetFD()
        defer { close(fd) }
        let capture = SessionLogCapture(directory: tmp, maxFileBytes: 100, targetFDs: [fd])

        try capture.begin(name: "t3")
        writeAll(String(repeating: "a", count: 300), to: fd)
        capture.end()

        let logSize = try FileManager.default
            .attributesOfItem(atPath: tmp.appendingPathComponent("session-t3.log").path)[.size] as! Int
        XCTAssertLessThanOrEqual(logSize, 100,
            "the cap is exact -- `allowed = min(n, maxFileBytes - logBytesWritten)` never overshoots")
        let originalSize = try FileManager.default
            .attributesOfItem(atPath: original.path)[.size] as! Int
        XCTAssertEqual(originalSize, 300, "pass-through must not be capped")
    }

    func testRotationKeepsAtMostMaxFilesLogs() throws {
        let (fd, _) = try makeTargetFD()
        defer { close(fd) }
        let capture = SessionLogCapture(directory: tmp, maxFiles: 3, targetFDs: [fd])

        for name in ["r1", "r2", "r3", "r4"] {
            try capture.begin(name: name)
            writeAll("session \(name)\n", to: fd)
            capture.end()
        }

        let logs = SessionLogCapture.sessionLogs(in: tmp).map { $0.lastPathComponent }
        XCTAssertEqual(logs.count, 3)
        XCTAssertFalse(logs.contains("session-r1.log"), "oldest log must be rotated out")
        XCTAssertTrue(logs.contains("session-r4.log"))
    }

    func testEndWithoutBeginIsANoOp() {
        let capture = SessionLogCapture(directory: tmp)
        capture.end() // must not crash or hang
    }

    func testDiagnosticsDirectoryIsExcludedFromBackup() throws {
        let (fd, _) = try makeTargetFD()
        defer { close(fd) }
        let capture = SessionLogCapture(directory: tmp, targetFDs: [fd])
        try capture.begin(name: "b1")
        capture.end()

        let values = try tmp.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true,
                       "diagnostics must never leave the device via a backup")
    }

    func testEndReturnsBoundedOnATimedOutPassThroughAndTheStragglerNeverContaminatesALaterSession() throws {
        // A pipe filled to capacity, whose read end nobody drains, models a
        // pass-through destination that genuinely blocks: the only way to
        // exercise end()'s bounded-timeout / abandoned-thread path
        // deterministically instead of relying on real stdout/stderr
        // backpressure.
        var sinkFDs: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&sinkFDs), 0)
        let (sinkReadEnd, sinkWriteEnd) = (sinkFDs[0], sinkFDs[1])
        defer { close(sinkReadEnd) }

        // Fill non-blocking so the fill loop itself can't hang, then restore
        // blocking mode so the capture's pass-through write actually blocks.
        // Track exactly how many bytes are backlogged: the write end is
        // deliberately never closed (see end()'s leaked-fd comment), so an
        // open-ended drain would just block again once caught up -- the
        // drain below must read precisely the known total and then stop.
        XCTAssertEqual(fcntl(sinkWriteEnd, F_SETFL, O_NONBLOCK), 0)
        let chunk = [UInt8](repeating: 0, count: 65536)
        var backlog = 0
        while true {
            let n = chunk.withUnsafeBufferPointer { write(sinkWriteEnd, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            backlog += n
        }
        XCTAssertEqual(fcntl(sinkWriteEnd, F_SETFL, 0), 0)

        let capture = SessionLogCapture(directory: tmp, targetFDs: [sinkWriteEnd], drainDeadline: 0.3)
        try capture.begin(name: "blocked")
        let stuckMessage = "stuck bytes\n"
        writeAll(stuckMessage, to: sinkWriteEnd)

        let start = Date.now
        capture.end()
        let elapsed = Date.now.timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.5,
            "end() must return near drainDeadline, not hang on a permanently blocked write")

        // The abandoned pump thread is still blocked inside write(saved,
        // ...) here. Starting a new session must not let it, once
        // unblocked, write its leftover bytes into the NEW session's log.
        try capture.begin(name: "after-timeout")
        let freshMessage = "fresh bytes\n"
        writeAll(freshMessage, to: sinkWriteEnd)

        // Drain exactly backlog + the two queued messages so both the
        // straggler's and the new session's blocked writes complete, then
        // stop -- reading further would block forever (write end never closes).
        let expectedTotal = backlog + stuckMessage.utf8.count + freshMessage.utf8.count
        var drained = 0
        var drainBuffer = [UInt8](repeating: 0, count: 65536)
        while drained < expectedTotal {
            let n = read(sinkReadEnd, &drainBuffer, min(drainBuffer.count, expectedTotal - drained))
            XCTAssertGreaterThan(n, 0)
            drained += n
        }
        Thread.sleep(forTimeInterval: 0.5) // let the straggler run past its now-unblocked write

        capture.end()

        let freshLog = try String(contentsOf: tmp.appendingPathComponent("session-after-timeout.log"),
                                  encoding: .utf8)
        XCTAssertTrue(freshLog.contains("fresh bytes"))
        XCTAssertFalse(freshLog.contains("stuck bytes"),
                       "a straggler from a timed-out end() must never write into a later session's log")
    }
}
