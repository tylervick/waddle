import XCTest
@testable import Waddle

/// Issue #394: when whatever reads the app's original stderr stopped
/// reading, the capture's pass-through write went to sleep, the tee filled
/// behind it, and every thread that then wrote to stdout or stderr slept
/// too. Under XCUITest that was the main thread, and the test failed on a
/// query timeout with the app frozen on its last frame.
///
/// These cases stand the original descriptor on a pipe and control who reads
/// it (`docs/learnings/dup2-fails-a-blocked-writer-with-sigpipe.md`).
final class SessionLogCaptureStalledReaderTests: XCTestCase {
    private var tmp: URL!
    /// Far more than the tee's pipe, the pass-through queue and the sink's
    /// pipe hold between them (64 KiB each), so a writer that gets through
    /// this much was not merely filling buffers.
    private static let payloadBytes = 4 * 1024 * 1024

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    /// The freeze itself: nobody reads the original, and a second thread
    /// writes more than every buffer in the way can hold.
    func testAWriterFinishesAlthoughNobodyReadsTheOriginal() throws {
        let sink = try Sink(full: true)
        let capture = SessionLogCapture(directory: tmp, maxFileBytes: 2 * Self.payloadBytes,
                                        targetFDs: [sink.writeEnd],
                                        drainDeadline: 0.3, stallGrace: 0.2)
        try capture.begin(name: "stalled")

        let payload = Self.pattern(count: Self.payloadBytes)
        let writer = PayloadWriter(fd: sink.writeEnd, payload: payload)
        // Whatever happens above, leave no thread asleep on the sink: the
        // old code's writer only ever finishes once something reads.
        defer { writer.finish(draining: sink) }

        XCTAssertTrue(writer.waitUntilReturned(timeout: 10),
                      "a thread writing to the captured descriptor slept because the original's reader had stalled")
        XCTAssertEqual(writer.written, payload.count)
        XCTAssertNil(writer.failure)

        capture.end()

        // Losing pass-through bytes in this state is the accepted cost. The
        // log is where they must still be, all of them and in order.
        let log = try Data(contentsOf: tmp.appendingPathComponent("session-stalled.log"))
        XCTAssertEqual(log.count, payload.count)
        XCTAssertTrue(log == Data(payload), "the session log lost or reordered bytes while the reader was stalled")
    }

    /// The other half of the bargain: a reader that keeps reading loses
    /// nothing, however much is written.
    func testAReaderThatDrainsGetsEveryByteInOrder() throws {
        let sink = try Sink(full: false)
        let reader = CollectingReader(sink: sink)
        let capture = SessionLogCapture(directory: tmp, maxFileBytes: 2 * Self.payloadBytes,
                                        targetFDs: [sink.writeEnd])
        try capture.begin(name: "draining")

        let payload = Self.pattern(count: Self.payloadBytes)
        let writer = PayloadWriter(fd: sink.writeEnd, payload: payload)
        defer { writer.finish(draining: nil) }
        XCTAssertTrue(writer.waitUntilReturned(timeout: 30))
        XCTAssertEqual(writer.written, payload.count)

        capture.end()

        XCTAssertTrue(reader.waitForCount(payload.count, timeout: 10),
                      "the original got \(reader.collected.count) of \(payload.count) bytes")
        XCTAssertTrue(reader.collected == payload, "pass-through lost, added or reordered bytes")
        let log = try Data(contentsOf: tmp.appendingPathComponent("session-draining.log"))
        XCTAssertTrue(log == Data(payload), "the session log lost or reordered bytes")
    }

    /// A stall is not for good. Once the reader reads again the original
    /// gets what is written from then on, and is told that there is a gap.
    func testPassThroughResumesWhenTheReaderReadsAgain() throws {
        let sink = try Sink(full: true)
        let capture = SessionLogCapture(directory: tmp, targetFDs: [sink.writeEnd],
                                        drainDeadline: 2, stallGrace: 0.2)
        try capture.begin(name: "resumes")

        let writer = PayloadWriter(fd: sink.writeEnd, payload: Self.pattern(count: Self.payloadBytes))
        defer { writer.finish(draining: sink) }
        XCTAssertTrue(writer.waitUntilReturned(timeout: 10), "the reader never counted as stalled")

        let reader = CollectingReader(sink: sink)
        let marker = Array("\nwritten after the stall\n".utf8)
        // The stall ends when a write to the original completes, which is
        // moments after the reader starts. Offer the marker until one lands.
        let deadline = Date.now.addingTimeInterval(10)
        while !reader.contains(marker), Date.now < deadline {
            _ = marker.withUnsafeBufferPointer { write(sink.writeEnd, $0.baseAddress, $0.count) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        capture.end()

        XCTAssertTrue(reader.contains(marker), "nothing reached the original after its reader came back")
        XCTAssertTrue(reader.contains(Array("bytes not passed through".utf8)),
                      "the original was not told that bytes are missing")
    }

    /// Bytes whose value depends on their position, so a dropped or
    /// reordered run cannot compare equal.
    private static func pattern(count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) }
    }
}

/// A pipe standing in for the original stderr. Nothing reads it unless a
/// case says so.
private struct Sink {
    let readEnd: Int32
    let writeEnd: Int32

    /// `full` leaves it filled to capacity, so the next write to it sleeps.
    init(full: Bool) throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        (readEnd, writeEnd) = (fds[0], fds[1])
        guard full else { return }
        _ = fcntl(writeEnd, F_SETFL, O_NONBLOCK)
        let chunk = [UInt8](repeating: 0, count: 65536)
        while chunk.withUnsafeBufferPointer({ write(writeEnd, $0.baseAddress, $0.count) }) > 0 {}
        _ = fcntl(writeEnd, F_SETFL, 0)
    }

    /// Empties whatever is in the pipe now, without waiting for more.
    func drain() {
        _ = fcntl(readEnd, F_SETFL, O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 65536)
        while read(readEnd, &buffer, buffer.count) > 0 {}
    }

    // No close(), for the reason SessionLogCaptureBlockedWriterTests gives:
    // a writer the capture abandoned may still be asleep on this pipe, and
    // closing the read end under it raises SIGPIPE.
}

/// A thread that writes one payload to a descriptor in 4 KiB writes and
/// reports how far it got.
private final class PayloadWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var failedWith: Int32?
    private var returned = false
    private var stopping = false

    init(fd: Int32, payload: [UInt8]) {
        let thread = Thread { [self] in
            payload.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count, !locked({ stopping }) {
                    let n = write(fd, raw.baseAddress! + offset, min(4096, raw.count - offset))
                    let code = errno
                    if n < 0 {
                        locked { failedWith = code }
                        break
                    }
                    offset += n
                    locked { count = offset }
                }
            }
            locked { returned = true }
        }
        thread.name = "payload writer"
        thread.start()
    }

    var written: Int { locked { count } }
    var failure: Int32? { locked { failedWith } }

    func waitUntilReturned(timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if locked({ returned }) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Ends the thread whatever state the case left it in, emptying `sink`
    /// so that a write asleep behind it completes.
    func finish(draining sink: Sink?) {
        locked { stopping = true }
        let deadline = Date.now.addingTimeInterval(10)
        while !locked({ returned }), Date.now < deadline {
            sink?.drain()
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A thread that reads a sink for the rest of the process's life and keeps
/// what it read.
private final class CollectingReader: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []

    init(sink: Sink) {
        let fd = sink.readEnd
        _ = fcntl(fd, F_SETFL, 0)
        let thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                lock.lock()
                bytes.append(contentsOf: buffer[..<n])
                lock.unlock()
            }
        }
        thread.name = "collecting reader"
        thread.start()
    }

    var collected: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    func waitForCount(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if collected.count >= count { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return collected.count >= count
    }

    func contains(_ needle: [UInt8]) -> Bool {
        Data(collected).range(of: Data(needle)) != nil
    }
}
