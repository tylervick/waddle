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

    /// Ending a session while the pump is still giving the reader its grace
    /// period: what the tee holds at that moment was accepted from its
    /// writer, so it belongs in the log, and `end()` must not sit the grace
    /// period out to get it there.
    func testEndingInsideTheGracePeriodStillLogsWhatTheTeeHolds() throws {
        let sink = try Sink(full: true)
        let capture = SessionLogCapture(directory: tmp, targetFDs: [sink.writeEnd],
                                        drainDeadline: 0.3, stallGrace: 30)
        try capture.begin(name: "ends-in-grace")

        // More than the pass-through takes before its queue is full (one
        // 4 KiB write in flight and 64 KiB queued), less than that plus the
        // tee's 64 KiB: the writer finishes without sleeping and leaves the
        // difference in the tee, behind a pump that is waiting for room.
        let payload = Self.pattern(count: 120 * 1024)
        let writer = PayloadWriter(fd: sink.writeEnd, payload: payload)
        defer { writer.finish(draining: sink) }
        XCTAssertTrue(writer.waitUntilReturned(timeout: 10), "the payload did not fit; the case proves nothing")
        XCTAssertEqual(writer.written, payload.count)

        let start = Date.now
        capture.end()
        XCTAssertLessThan(Date.now.timeIntervalSince(start), 5, "end() waited out the grace period")

        let log = try Data(contentsOf: tmp.appendingPathComponent("session-ends-in-grace.log"))
        XCTAssertEqual(log.count, payload.count, "bytes still in the tee when the session ended never reached the log")
        XCTAssertTrue(log == Data(payload))
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
        if writer.hasReturned { reader.shutDown(closing: sink) }
    }

    /// A reader that is reading, only not as fast as the last burst was
    /// written, has not stalled. Ending the session behind it must cost it
    /// nothing: what the tee and the queue held still arrives, in order, and
    /// it is not told that it stopped reading.
    func testEndingBehindAReaderThatIsStillDrainingDropsNothing() throws {
        let sink = try Sink(full: false)
        // 4 KiB every 5 ms: far slower than the burst, half a second for
        // all of it.
        let reader = CollectingReader(sink: sink, chunk: 4096, pause: 0.005)
        let capture = SessionLogCapture(directory: tmp, targetFDs: [sink.writeEnd])
        try capture.begin(name: "still-draining")

        // Several times what the tee and the queue hold between them, so
        // the session ends with both full.
        let payload = Self.pattern(count: 400_000)
        let writer = PayloadWriter(fd: sink.writeEnd, payload: payload)
        defer { writer.finish(draining: nil) }
        XCTAssertTrue(writer.waitUntilReturned(timeout: 30))
        XCTAssertEqual(writer.written, payload.count)

        capture.end()

        XCTAssertTrue(reader.waitForCount(payload.count, timeout: 10),
                      "the original got \(reader.collected.count) of \(payload.count) bytes")
        XCTAssertTrue(reader.collected == payload, "pass-through lost, added or reordered bytes at the end of a session")
        if writer.hasReturned { reader.shutDown(closing: sink) }
    }

    /// Issue #410: `end()` takes the tee's write end away from the captured
    /// descriptor, but not from a duplicate of it made during the session.
    /// Whatever is written to such a duplicate afterwards still reaches the
    /// pump, and must not pile up in memory behind a reader that is not
    /// reading.
    func testWritesToADuplicateAfterTheSessionDoNotPileUpInMemory() throws {
        let sink = try Sink(full: true)
        // A grace period longer than the case: the reader has not been
        // found stalled when the session ends, which is the state in which
        // nothing used to be dropped at all.
        let capture = SessionLogCapture(directory: tmp, targetFDs: [sink.writeEnd],
                                        drainDeadline: 0.3, stallGrace: 30)
        try capture.begin(name: "duplicate")
        let duplicate = dup(sink.writeEnd)
        XCTAssertGreaterThanOrEqual(duplicate, 0)
        capture.end()

        let payload = Self.pattern(count: 8 * 1024 * 1024)
        let writer = PayloadWriter(fd: duplicate, payload: payload)
        defer {
            writer.finish(draining: sink)
            // Only once the writer is done with it. This is EOF for the
            // abandoned pump, which then lets its writer thread go.
            if writer.hasReturned { Darwin.close(duplicate) }
        }
        XCTAssertTrue(writer.waitUntilReturned(timeout: 20),
                      "the bound put a thread to sleep; it must drop, not block")
        XCTAssertEqual(writer.written, payload.count)

        // What the pass-through kept is what comes out once somebody reads.
        // The sink's own 64 KiB of filler comes first; everything after
        // that was held in memory.
        let reader = CollectingReader(sink: sink)
        let arrived = reader.countOnceQuiet(for: 0.5, timeout: 20)
        XCTAssertLessThan(arrived, 1024 * 1024,
                          "\(arrived) bytes were waiting for the reader; all but the sink's 64 KiB of them were held in memory")
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
        if writer.hasReturned { reader.shutDown(closing: sink) }
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

    // No close() here, for the reason SessionLogCaptureBlockedWriterTests
    // gives: a writer the capture abandoned may still be asleep on this
    // pipe, and closing the read end under it raises SIGPIPE. The cases with
    // a reader close through `CollectingReader.shutDown`, which can tell.
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
    var hasReturned: Bool { locked { returned } }
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

/// A thread that reads a sink until its write end closes and keeps what it
/// read.
private final class CollectingReader: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var thread: Thread!

    /// Reads at most `chunk` bytes at a time and sleeps `pause` after each
    /// read; the defaults are a reader that keeps up with anything.
    init(sink: Sink, chunk: Int = 65536, pause: TimeInterval = 0) {
        let fd = sink.readEnd
        _ = fcntl(fd, F_SETFL, 0)
        thread = Thread { [self] in
            var buffer = [UInt8](repeating: 0, count: chunk)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { break }
                lock.lock()
                bytes.append(contentsOf: buffer[..<n])
                lock.unlock()
                if pause > 0 { Thread.sleep(forTimeInterval: pause) }
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

    /// Ends the thread and gives the pipe back, once the capture has ended
    /// and nothing of the case's own still writes to the sink. Closing the
    /// case's write end is EOF for the reader unless the capture abandoned a
    /// writer, which holds a duplicate of it; then the reader never exits,
    /// and the read end stays open rather than be closed under that writer.
    func shutDown(closing sink: Sink) {
        Darwin.close(sink.writeEnd)
        let deadline = Date.now.addingTimeInterval(2)
        while !thread.isFinished, Date.now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if thread.isFinished { Darwin.close(sink.readEnd) }
    }

    /// How many bytes have arrived, once no more have for `quiet` seconds.
    func countOnceQuiet(for quiet: TimeInterval, timeout: TimeInterval) -> Int {
        let deadline = Date.now.addingTimeInterval(timeout)
        var last = collected.count
        var lastChange = Date.now
        while Date.now < deadline, Date.now.timeIntervalSince(lastChange) < quiet {
            Thread.sleep(forTimeInterval: 0.02)
            let count = collected.count
            if count != last { (last, lastChange) = (count, Date.now) }
        }
        return last
    }

    func contains(_ needle: [UInt8]) -> Bool {
        Data(collected).range(of: Data(needle)) != nil
    }
}
