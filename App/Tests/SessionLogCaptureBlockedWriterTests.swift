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
        // The writer below is only asleep on the tee while the capture is
        // still giving the full sink its grace period; after that the
        // capture drops pass-through bytes and the writer runs freely
        // (issue #394). A grace period far longer than the case keeps
        // `end()` inside it however slowly this thread gets there.
        let capture = SessionLogCapture(directory: tmp, targetFDs: [sink.writeEnd], drainDeadline: 0.3,
                                        stallGrace: 30)
        try capture.begin(name: "writer-asleep-on-the-tee")

        // The pump cannot pass anything through to the full sink, so this
        // writer fills the tee's own pipe and then sleeps in write().
        let writer = Writer(fd: sink.writeEnd)
        defer { writer.finish(draining: sink) }
        guard writer.waitUntilAsleep() else {
            capture.end()
            return XCTFail(writer.setupFailure)
        }

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
        guard writer.waitUntilAsleep() else { return XCTFail(writer.setupFailure) }

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
    /// The writer thread's own Mach port, so its state can be read.
    private var machThread: thread_act_t = 0
    /// What the last poll of `waitUntilAsleep` found.
    private var lastSeen = "nothing; never polled"

    init(fd: Int32) {
        let thread = Thread { [self] in
            locked { machThread = mach_thread_self() }
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

    deinit {
        if machThread != 0 { mach_port_deallocate(mach_task_self_, machThread) }
    }

    /// The errno of the write that failed, if one did.
    var failure: Int32? { locked { failedWith } }

    /// True once the thread is verifiably asleep inside write(), on several
    /// consecutive polls: the scheduler reports it waiting rather than
    /// running or runnable, its program counter is in write(), and the byte
    /// count has not moved.
    ///
    /// The byte count alone cannot tell asleep in write() from not scheduled
    /// between two writes, and on a starved runner that difference let a swap
    /// land while nothing was in write() (issue #559). A thread that is
    /// merely descheduled is runnable, not waiting, and one waiting anywhere
    /// else in its loop, on the lock for instance, is stopped in another
    /// function.
    ///
    /// Whether the pipe has room is deliberately not one of the facts. Under
    /// load `poll` reported POLLOUT on the tee while the writer was waiting
    /// in write() with its count still, which failed the setup once in 200
    /// iterations although the writer was exactly where the case needs it.
    func waitUntilAsleep(timeout: TimeInterval = 5) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        var last = -1
        var confirmedFor = 0
        while Date.now < deadline {
            let (count, done, port) = locked { (written, returned, machThread) }
            if done {
                lastSeen = "the thread returned, failing with errno \(failure.map(String.init) ?? "none")"
                return false
            }
            let state = port == 0 ? nil : Self.runState(port)
            let function = port == 0 ? nil : Self.stoppedIn(port)
            lastSeen = "run state \(state.map(String.init) ?? "unknown"), stopped in \(function ?? "unknown"), "
                + "\(count) bytes written" + (count == last ? "" : ", still moving")
            let asleep = count == last && state == TH_STATE_WAITING && function == "write"
            confirmedFor = asleep ? confirmedFor + 1 : 0
            last = count
            if confirmedFor >= 5 { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// The failure for a case whose writer `waitUntilAsleep` never confirmed.
    /// It is the setup that failed, not the behaviour under test, so the case
    /// stops there instead of going on to report a changed premise.
    var setupFailure: String {
        "setup failed: the writer was never seen asleep inside write(), so the case proves nothing. "
            + "Last seen: \(lastSeen)"
    }

    /// The scheduler's run state for the thread. A thread waiting on an
    /// event is `TH_STATE_WAITING`; one that is only waiting for a CPU is not.
    private static func runState(_ thread: thread_act_t) -> integer_t? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.run_state : nil
    }

    /// The function holding the thread's user-space program counter. A
    /// thread asleep in the write() system call is stopped in `write`.
    private static func stoppedIn(_ thread: thread_act_t) -> String? {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS,
              let pc = UnsafeRawPointer(bitPattern: UInt(state.__pc)) else { return nil }
        var symbol = Dl_info()
        guard dladdr(pc, &symbol) != 0, let name = symbol.dli_sname else { return nil }
        return String(cString: name)
        #else
        #error("stoppedIn reads arm64 thread state; the simulator build is arm64-only")
        #endif
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
