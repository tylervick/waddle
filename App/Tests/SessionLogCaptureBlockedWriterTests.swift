import XCTest
@testable import Waddle

/// How many SIGPIPEs the test's handler has seen. A signal handler can reach
/// nothing but a global.
nonisolated(unsafe) private var sigpipesSeen: Int32 = 0

/// Issue #365: the app vanished from UI runs with no crash report, because it
/// was being killed by SIGPIPE as a session began or ended.
///
/// `SessionLogCapture` swaps a descriptor with `dup2`. On Darwin that fails
/// every thread asleep in `write()` on the descriptor being replaced with
/// EPIPE, although the pipe's reader is alive, and EPIPE raises SIGPIPE,
/// whose default action ends the process. A writer is only asleep there when
/// the pipe is full, which is why this needed a slow machine to show itself
/// (`docs/learnings/dup2-fails-a-blocked-writer-with-sigpipe.md`).
///
/// These cases put a writer to sleep on a full pipe and swap the descriptor
/// under it. The handler turns what would be the death of the test host into
/// a count.
final class SessionLogCaptureBlockedWriterTests: XCTestCase {
    private var tmp: URL!
    private var previousAction = sigaction()
    /// SIGPIPE is sent to the process, so the handler may run on another
    /// thread a moment after the write that raised it has returned.
    private static let signalSettle: TimeInterval = 0.2

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("diag-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        sigpipesSeen = 0
        var counting = sigaction()
        counting.__sigaction_u.__sa_handler = { _ in sigpipesSeen += 1 }
        XCTAssertEqual(sigaction(SIGPIPE, &counting, &previousAction), 0)
    }

    override func tearDownWithError() throws {
        sigaction(SIGPIPE, &previousAction, nil)
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: The two swaps

    /// The one CI hit: `end()` puts the original descriptor back over the
    /// tee's pipe while another thread is asleep writing into the tee.
    func testEndingASessionDoesNotSignalAWriterAsleepOnTheTee() throws {
        let sink = try FullPipe()
        let capture = SessionLogCapture(directory: tmp, targetFDs: [sink.writeEnd], drainDeadline: 0.3)
        try capture.begin(name: "writer-asleep-on-the-tee")

        // The pump cannot pass anything through to the full sink, so this
        // writer fills the tee's own pipe and then sleeps in write().
        let writer = Writer(fd: sink.writeEnd)
        defer { writer.finish(draining: sink) }
        XCTAssertTrue(writer.waitUntilAsleep(), "the writer never blocked; the case proves nothing")

        capture.end()

        XCTAssertTrue(writer.waitUntilReturned(), "the swap did not disturb the writer; the premise changed")
        XCTAssertEqual(writer.failure, EPIPE, "the premise: Darwin fails the sleeping write with EPIPE")
        Thread.sleep(forTimeInterval: Self.signalSettle)
        XCTAssertEqual(sigpipesSeen, 0, "ending a session raised SIGPIPE, which by default kills the app")
    }

    /// The same swap at the other end: `begin()` puts the tee over the
    /// original descriptor while another thread is asleep writing to that.
    func testBeginningASessionDoesNotSignalAWriterAsleepOnTheOriginal() throws {
        let sink = try FullPipe()
        let writer = Writer(fd: sink.writeEnd)
        defer { writer.finish(draining: sink) }
        XCTAssertTrue(writer.waitUntilAsleep(), "the writer never blocked; the case proves nothing")

        let capture = SessionLogCapture(directory: tmp, targetFDs: [sink.writeEnd], drainDeadline: 0.3)
        try capture.begin(name: "writer-asleep-on-the-original")
        defer { capture.end() }

        XCTAssertTrue(writer.waitUntilReturned(), "the swap did not disturb the writer; the premise changed")
        XCTAssertEqual(writer.failure, EPIPE, "the premise: Darwin fails the sleeping write with EPIPE")
        Thread.sleep(forTimeInterval: Self.signalSettle)
        XCTAssertEqual(sigpipesSeen, 0, "beginning a session raised SIGPIPE, which by default kills the app")
    }

    /// The capture borrows the original descriptor; it must hand it back
    /// behaving as it found it. A write to a pipe whose reader really has
    /// gone is still an error the process is told about.
    func testTheOriginalDescriptorStillSignalsOnceTheSessionIsOver() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let (readEnd, writeEnd) = (fds[0], fds[1])
        defer { Darwin.close(writeEnd) }

        let capture = SessionLogCapture(directory: tmp, targetFDs: [writeEnd], drainDeadline: 0.3)
        try capture.begin(name: "hands-it-back")
        capture.end()
        XCTAssertEqual(fcntl(writeEnd, F_GETNOSIGPIPE), 0, "the original was left marked no-SIGPIPE")

        Darwin.close(readEnd)
        XCTAssertEqual(write(writeEnd, "x", 1), -1)
        Thread.sleep(forTimeInterval: Self.signalSettle)
        XCTAssertEqual(sigpipesSeen, 1, "a write to a pipe with no reader should still raise SIGPIPE")
    }
}

/// A pipe filled to capacity that nobody is reading: a destination that
/// blocks whoever writes to it next.
private struct FullPipe {
    let readEnd: Int32
    let writeEnd: Int32

    init() throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw POSIXError(.EMFILE) }
        (readEnd, writeEnd) = (fds[0], fds[1])
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

    // There is deliberately no close(). A pump the capture abandoned may
    // still be asleep writing to this pipe, and closing the read end under
    // it is a real SIGPIPE, possibly after the case has put the default
    // action back. Two descriptors leaked per case is the cheaper mistake.
}

/// A thread that writes to a descriptor until a write fails or it is told to
/// stop, and reports how far it got.
private final class Writer: @unchecked Sendable {
    private let lock = NSLock()
    private var written = 0
    private var failedWith: Int32?
    private var returned = false
    private var stopping = false

    init(fd: Int32) {
        let thread = Thread { [self] in
            let chunk = [UInt8](repeating: 0x2E, count: 4096)
            while !locked({ stopping }) {
                let n = chunk.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
                let code = errno
                if n < 0 {
                    locked { failedWith = code }
                    break
                }
                locked { written += n }
            }
            locked { returned = true }
        }
        thread.name = "blocked writer"
        thread.start()
    }

    /// The errno of the write that failed, if one did.
    var failure: Int32? { locked { failedWith } }

    /// True once the byte count has stopped moving while the thread is still
    /// inside its loop: it is asleep in write().
    func waitUntilAsleep(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        var last = -1
        var stillFor = 0
        while Date.now < deadline {
            let (count, done) = locked { (written, returned) }
            if done { return false }
            stillFor = count == last ? stillFor + 1 : 0
            last = count
            if stillFor >= 5 { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func waitUntilReturned(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if locked({ returned }) { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return false
    }

    /// Ends the thread whatever state the case left it in: tells it to stop
    /// and keeps emptying `sink` so that a write still asleep on it, this
    /// thread's or an abandoned pump's, completes instead of staying stuck.
    func finish(draining sink: FullPipe) {
        locked { stopping = true }
        let start = Date.now
        while Date.now.timeIntervalSince(start) < 5 {
            sink.drain()
            if locked({ returned }), Date.now.timeIntervalSince(start) > 0.3 { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
