import Foundation

/// Tees writes made to a set of file descriptors (stdout/stderr in
/// production -- the in-process Woof engine prints its console there) into a
/// per-session log file, while passing every byte through to the original
/// destination so Xcode's console keeps working. begin/end brackets one
/// engine session.
///
/// The pass-through is best effort and the log is not: when whatever reads
/// the original destination stops reading, the console loses bytes rather
/// than the app's threads going to sleep in `write()` (issue #394).
final class SessionLogCapture {
    /// One captured target: its original fd number, a dup of the original
    /// destination for pass-through, the thread pumping the pipe, and the
    /// writer that owns every write to `saved`.
    private struct Capture {
        let target: Int32
        let saved: Int32
        let thread: Thread
        let passThrough: PassThrough

        var isFinished: Bool { thread.isFinished && passThrough.isFinished }
    }

    let directory: URL
    let maxFileBytes: Int
    let maxFiles: Int
    private let targetFDs: [Int32]
    private let drainDeadline: TimeInterval
    private let stallGrace: TimeInterval

    private var captures: [Capture] = []
    private let logLock = NSLock()
    private var logFD: Int32 = -1
    private var logBytesWritten = 0
    /// Bumped by every begin(), under logLock. A pump thread captures the
    /// epoch it was spawned with and only writes to logFD while that epoch
    /// still matches -- otherwise a straggler abandoned by a timed-out
    /// end() (see end()'s close comment) could resume later and write a
    /// PRIOR session's bytes into whatever session is current by then.
    private var sessionEpoch = 0
    private var active = false

    init(directory: URL, maxFileBytes: Int = 1_000_000, maxFiles: Int = 3,
         targetFDs: [Int32] = [STDOUT_FILENO, STDERR_FILENO],
         drainDeadline: TimeInterval = 2,
         stallGrace: TimeInterval = 2) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.targetFDs = targetFDs
        self.drainDeadline = drainDeadline
        self.stallGrace = stallGrace
    }

    /// `session-*.log` in `directory`, sorted oldest-first by modification
    /// date. Used by rotation here and by the exporter to bundle logs.
    static func sessionLogs(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("session-")
                   && $0.pathExtension == "log" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da < db
            }
    }

    func begin(name: String) throws {
        guard !active else { return }
        try DiagnosticsPaths.ensureExcludedDirectory(directory)

        // Rotate BEFORE creating the new log: keep the newest maxFiles - 1 so
        // the new file makes exactly maxFiles.
        let existing = Self.sessionLogs(in: directory)
        if existing.count > maxFiles - 1 {
            for old in existing.prefix(existing.count - (maxFiles - 1)) {
                try? FileManager.default.removeItem(at: old)
            }
        }

        let logURL = directory.appendingPathComponent("session-\(name).log")
        let newLogFD = open(logURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard newLogFD >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // logFD/logBytesWritten/sessionEpoch are shared with pump threads --
        // including any straggler still draining from a prior timed-out
        // end() -- so every write goes under logLock, this one included.
        logLock.lock()
        logFD = newLogFD
        logBytesWritten = 0
        sessionEpoch += 1
        let epoch = sessionEpoch
        logLock.unlock()

        for target in targetFDs {
            var fds: [Int32] = [0, 0]
            guard pipe(&fds) == 0 else { continue }
            let (readEnd, writeEnd) = (fds[0], fds[1])
            // Swapping a descriptor with dup2 fails every thread asleep in
            // write() on the one being replaced with EPIPE, and EPIPE raises
            // SIGPIPE, which ends the process without a crash report (issue
            // #365). Both swaps do it: this one to a writer asleep on the
            // original, end()'s to a writer asleep on the tee. The tee is
            // ours, so it never signals. The original is borrowed, so it is
            // only kept from signalling across the swap.
            _ = fcntl(writeEnd, F_SETNOSIGPIPE, 1)
            let saved = dup(target)
            let originalSignals = fcntl(target, F_GETNOSIGPIPE) == 0
            if originalSignals { _ = fcntl(target, F_SETNOSIGPIPE, 1) }
            guard saved >= 0, dup2(writeEnd, target) >= 0 else {
                if originalSignals { _ = fcntl(target, F_SETNOSIGPIPE, 0) }
                close(readEnd); close(writeEnd)
                if saved >= 0 { close(saved) }
                continue
            }
            // dup2 does not return until the writers it woke have left
            // write(), so none of them can see the setting come back.
            if originalSignals { _ = fcntl(saved, F_SETNOSIGPIPE, 0) }
            close(writeEnd) // target now IS the write end; drop our extra ref

            let passThrough = PassThrough(to: saved, stallGrace: stallGrace,
                                          name: "SessionLogCapture pass-through fd \(target)")
            let thread = Thread { [weak self] in
                self?.pump(from: readEnd, passThrough: passThrough, epoch: epoch)
                // Reached with or without `self`: the writer must always be
                // told there is nothing more coming, or it never exits.
                passThrough.finish()
                close(readEnd)
            }
            thread.name = "SessionLogCapture fd \(target)"
            thread.start()
            captures.append(Capture(target: target, saved: saved, thread: thread,
                                    passThrough: passThrough))
        }
        active = true
    }

    func end() {
        guard active else { return }
        // Restoring the original fd over the pipe's write end closes the
        // process's last reference to it, so each pump loop sees EOF and
        // exits after draining whatever is still buffered. A thread asleep
        // in write() on the tee at this moment has that write failed with
        // EPIPE and its bytes are lost; begin() made sure that is all that
        // happens to it.
        for capture in captures {
            dup2(capture.saved, capture.target)
        }
        // A pump waiting out `stallGrace` for room in its queue would
        // otherwise still be waiting when the log is closed below, and what
        // is left in the tee would never be logged. From here on it reads
        // the tee straight through to EOF, and the queue takes what the
        // tee held however full it is: nothing can be written to the tee
        // any more, so that is one pipe's worth at most.
        for capture in captures {
            capture.passThrough.stopWaiting()
        }
        // Wait for the pumps and their writers to drain -- bounded, never
        // indefinite: EOF is already in flight, but a pathological blocked
        // pass-through write must not hang session teardown on the main
        // thread.
        let deadline = Date.now.addingTimeInterval(drainDeadline)
        while captures.contains(where: { !$0.isFinished }),
              Date.now < deadline {
            usleep(1_000)
        }
        // Close `saved` only for writers that actually finished with it. A
        // writer still running past the deadline may be mid `write(saved,
        // ...)`; closing the fd out from under that write would let a LATER
        // open() reuse the same fd number, and the straggler's write could
        // then land in whatever that number now points to (e.g. the very
        // next session's log). A leaked fd on this pathological path is
        // bounded -- at most one per abandoned writer -- and harmless; a
        // reissued fd number written to by a straggler is silent
        // corruption, which is strictly worse.
        for capture in captures where capture.passThrough.isFinished {
            close(capture.saved)
        }
        captures.removeAll()
        // Closing logFD under the lock, together with the epoch bump in the
        // next begin(), is what neutralizes a straggler still looping past
        // this point: by the time it re-acquires logLock it finds either
        // logFD < 0 or a stale epoch and skips its log write, so it can
        // never touch this or a later session's log file.
        logLock.lock()
        if logFD >= 0 { close(logFD); logFD = -1 }
        logLock.unlock()
        active = false
    }

    private func pump(from readEnd: Int32, passThrough: PassThrough, epoch: Int) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readEnd, &buffer, buffer.count)
            guard n > 0 else { break }
            buffer.withUnsafeBytes { raw in
                // The log first: it is a file, so this write returns, where
                // handing the bytes to the pass-through may wait out
                // `stallGrace`. Neither depends on the other succeeding.
                logLock.lock()
                // epoch == sessionEpoch is what stops a straggler abandoned
                // by a timed-out end() from writing a prior session's bytes
                // into a session that has since begun (see end()'s comment).
                if logFD >= 0 && epoch == sessionEpoch && logBytesWritten < maxFileBytes {
                    let allowed = min(n, maxFileBytes - logBytesWritten)
                    let writtenToLog = write(logFD, raw.baseAddress!, allowed)
                    if writtenToLog > 0 { logBytesWritten += writtenToLog }
                }
                logLock.unlock()
                passThrough.offer(UnsafeRawBufferPointer(rebasing: raw[..<n]))
            }
        }
    }
}

/// Owns every write to one capture's original destination, on a thread of
/// its own, so that a destination nobody is reading can put only that thread
/// to sleep.
///
/// The pump used to make these writes itself. Under XCUITest the original
/// stderr is a pty that `xcodebuild` reads; when it stopped reading, the pump
/// slept in `write()`, the tee filled behind it, and every thread that then
/// logged slept too, the main thread among them (issue #394).
///
/// Bytes wait here in a bounded queue. A pump that finds the queue full
/// waits up to `stallGrace` for room, which is what keeps a reader that is
/// merely slow from losing anything. Past that the reader is taken to be
/// stalled and bytes are dropped without waiting, until a write to the
/// destination completes again.
private final class PassThrough: @unchecked Sendable {
    /// As much as a pipe holds: with the tee's own pipe in front of it, a
    /// reader can fall about 128 KiB behind before anything waits.
    private static let capacity = 65536

    private let fd: Int32
    private let stallGrace: TimeInterval
    private let condition = NSCondition()
    private var pending: [UInt8] = []
    private var stalled = false
    private var dropped = 0
    private var finishing = false
    private var waits = true
    private var thread: Thread!

    init(to fd: Int32, stallGrace: TimeInterval, name: String) {
        self.fd = fd
        self.stallGrace = stallGrace
        pending.reserveCapacity(Self.capacity)
        thread = Thread { [self] in run() }
        thread.name = name
        thread.start()
    }

    /// True once the writer has made its last write to the descriptor.
    var isFinished: Bool { thread.isFinished }

    /// Queues `bytes` for the destination, or drops them if its reader has
    /// stalled. Waits at most `stallGrace`, and not at all while stalled or
    /// once the session is ending.
    func offer(_ bytes: UnsafeRawBufferPointer) {
        condition.lock()
        defer { condition.unlock() }
        if !stalled && pending.count + bytes.count > Self.capacity {
            let deadline = Date.now.addingTimeInterval(stallGrace)
            var graceRanOut = false
            while waits && pending.count + bytes.count > Self.capacity {
                if !condition.wait(until: deadline) {
                    graceRanOut = true
                    break
                }
            }
            // Only a reader that used up its grace has stalled. A wait cut
            // short by `stopWaiting()` says nothing about the reader, which
            // may be reading and merely behind; its bytes are queued past
            // `capacity` below instead of being dropped.
            if graceRanOut {
                stalled = pending.count + bytes.count > Self.capacity
            }
        }
        // While stalled everything is dropped, room or no room, so that what
        // is missing is one run of bytes and the note below can stand
        // exactly where it was.
        if stalled {
            dropped += bytes.count
            return
        }
        pending.append(contentsOf: bytes)
        condition.broadcast()
    }

    /// The session is ending: `offer` no longer waits for room, now or in a
    /// call already waiting, so the pump is never kept from the tee. Unless
    /// the reader had already stalled, what the pump still offers is queued
    /// over `capacity`. That is bounded by what the tee held when its write
    /// end was taken away, and it is what lets a reader that is behind, but
    /// reading, have the end of the session (pull request 399's review).
    func stopWaiting() {
        condition.lock()
        waits = false
        condition.broadcast()
        condition.unlock()
    }

    /// Nothing more will be offered: write what is queued, then exit.
    func finish() {
        condition.lock()
        finishing = true
        condition.broadcast()
        condition.unlock()
    }

    private func run() {
        var batch: [UInt8] = []
        batch.reserveCapacity(Self.capacity)
        condition.lock()
        while true {
            while pending.isEmpty && !finishing { condition.wait() }
            if pending.isEmpty { break }
            swap(&batch, &pending)
            condition.broadcast() // the queue has room again
            condition.unlock()

            let completed = writeAll(batch)
            batch.removeAll(keepingCapacity: true)

            condition.lock()
            if completed && stalled {
                // The reader is reading again. Say what it missed, in the
                // place it missed it: after what was queued before the
                // stall, before anything offered from here on.
                pending.append(contentsOf:
                    "\n[SessionLogCapture: \(dropped) bytes not passed through; the reader had stopped reading]\n".utf8)
                dropped = 0
                stalled = false
            }
        }
        condition.unlock()
    }

    /// False if a write failed, in which case the rest of the batch is
    /// dropped, as the pump always did with a chunk it could not write.
    private func writeAll(_ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written < 0 && errno == EINTR { continue }
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}
