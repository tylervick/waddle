import Foundation

/// Tees writes made to a set of file descriptors (stdout/stderr in
/// production -- the in-process Woof engine prints its console there) into a
/// per-session log file, while passing every byte through to the original
/// destination so Xcode's console keeps working. begin/end brackets one
/// engine session.
final class SessionLogCapture {
    /// One captured target: its original fd number, a dup of the original
    /// destination for pass-through, and the thread pumping the pipe.
    private struct Capture {
        let target: Int32
        let saved: Int32
        let thread: Thread
    }

    let directory: URL
    let maxFileBytes: Int
    let maxFiles: Int
    private let targetFDs: [Int32]
    private let drainDeadline: TimeInterval

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
         drainDeadline: TimeInterval = 2) {
        self.directory = directory
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
        self.targetFDs = targetFDs
        self.drainDeadline = drainDeadline
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
            let saved = dup(target)
            guard saved >= 0, dup2(writeEnd, target) >= 0 else {
                close(readEnd); close(writeEnd)
                if saved >= 0 { close(saved) }
                continue
            }
            close(writeEnd) // target now IS the write end; drop our extra ref

            let thread = Thread { [weak self] in
                self?.pump(from: readEnd, passThroughTo: saved, epoch: epoch)
            }
            thread.name = "SessionLogCapture fd \(target)"
            thread.start()
            captures.append(Capture(target: target, saved: saved, thread: thread))
        }
        active = true
    }

    func end() {
        guard active else { return }
        // Restoring the original fd over the pipe's write end closes the
        // process's last reference to it, so each pump loop sees EOF and
        // exits after draining whatever is still buffered.
        for capture in captures {
            dup2(capture.saved, capture.target)
        }
        // Wait for the pumps to drain -- bounded, never indefinite: EOF is
        // already in flight, but a pathological blocked pass-through write
        // must not hang session teardown on the main thread.
        let deadline = Date.now.addingTimeInterval(drainDeadline)
        while captures.contains(where: { !$0.thread.isFinished }),
              Date.now < deadline {
            usleep(1_000)
        }
        // Close `saved` only for threads that actually finished with it. A
        // thread still running past the deadline may be mid `write(saved,
        // ...)`; closing the fd out from under that write would let a LATER
        // open() reuse the same fd number, and the straggler's write could
        // then land in whatever that number now points to (e.g. the very
        // next session's log). A leaked fd on this pathological path is
        // bounded -- at most one per abandoned pump -- and harmless; a
        // reissued fd number written to by a straggler is silent
        // corruption, which is strictly worse.
        for capture in captures where capture.thread.isFinished {
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

    private func pump(from readEnd: Int32, passThroughTo original: Int32, epoch: Int) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(readEnd, &buffer, buffer.count)
            guard n > 0 else { break }
            buffer.withUnsafeBytes { raw in
                // Pass through first -- the console must never lose bytes
                // even if the log write fails or the cap has been hit.
                var offset = 0
                while offset < n {
                    let written = write(original, raw.baseAddress! + offset,
                                        n - offset)
                    if written <= 0 { break }
                    offset += written
                }
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
            }
        }
        close(readEnd)
    }
}
