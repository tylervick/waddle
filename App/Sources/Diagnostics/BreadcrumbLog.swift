import Foundation

/// One app-level event worth leaving a trace of. The cases are the entire
/// vocabulary on purpose, and rendering lives here rather than at the call
/// sites: the "names only, no paths" rule of info.txt is then enforced in
/// exactly one place.
enum BreadcrumbEvent {
    case appLaunch
    case scenePhase(from: String, to: String)
    case sessionBegin(name: String)
    case sessionEnd(exitCode: Int32, engineMessage: String?)
    case alertPresented(title: String)
    case alertDismissed

    var text: String {
        switch self {
        case .appLaunch:
            return "app launch"
        case .scenePhase(let from, let to):
            return "scene: \(Self.sanitized(from)) -> \(Self.sanitized(to))"
        case .sessionBegin(let name):
            return "session begin: \(Self.sanitized(name))"
        case .sessionEnd(let exitCode, let engineMessage):
            // The engine's message is only meaningful alongside a failure --
            // on a clean exit the errmsg buffer still holds whatever the
            // previous run left there.
            guard exitCode != 0, let engineMessage, !engineMessage.isEmpty else {
                return "session end: exit \(exitCode)"
            }
            return "session end: exit \(exitCode) | \(Self.sanitized(engineMessage))"
        case .alertPresented(let title):
            return "alert presented: \(Self.sanitized(title))"
        case .alertDismissed:
            return "alert dismissed"
        }
    }

    /// Collapses a value to one safe line: no newlines (one event is one
    /// line, and the reader counts lines), no filesystem paths -- a token
    /// containing `/` is reduced to its last component, which is how the
    /// engine's own "Failed to load <path>" text stays inside info.txt's
    /// names-only envelope -- and a bounded length, so one runaway engine
    /// message cannot evict the whole trail from the ring buffer.
    static func sanitized(_ value: String, maxLength: Int = 200) -> String {
        let flattened = value
            .split(whereSeparator: { $0.isWhitespace })
            .map { token -> Substring in
                guard token.contains("/") else { return token }
                return token.split(separator: "/").last ?? ""
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flattened.count > maxLength
            ? String(flattened.prefix(maxLength)) + "..."
            : flattened
    }
}

/// A small, launch-spanning trail of app-level events, written beside the
/// engine session logs and bundled by the same export.
///
/// It exists because the session logs stop at whatever the engine last
/// printed, which is exactly the wrong place when the app is stuck *after*
/// the engine exited (issue #95: a non-dismissable error alert, force-quit,
/// and no evidence of it anywhere -- MetricKit stays silent too, because the
/// main thread was never blocked). An "alert presented" line with no matching
/// "alert dismissed" before the next "app launch" is that evidence.
///
/// Same privacy envelope as info.txt: names only, no paths, no WAD contents,
/// and nothing leaves the device except through the user's own export.
final class BreadcrumbLog: @unchecked Sendable {
    static let fileName = "breadcrumbs.log"

    /// The app's log. Same shape as `DiagnosticsMetricSubscriber.shared`: a
    /// process-wide instance is what makes a trail spanning launches, scenes
    /// and sessions possible at all.
    static let shared = BreadcrumbLog(directory: DiagnosticsPaths.directory)

    let directory: URL
    /// Ring-buffer cap. Whole lines are evicted from the *front*, unlike
    /// SessionLogCapture's cap which simply stops writing once it is hit: a
    /// stuck-state trail is only useful if the newest events survive.
    let maxBytes: Int

    // Each record() is a read-modify-write of one small file, so two
    // concurrent ones could otherwise interleave into a torn trail.
    private let lock = NSLock()

    init(directory: URL, maxBytes: Int = 64_000) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// The breadcrumb file when it exists -- the exporter's allowlist entry.
    /// Empty on a fresh install that has never recorded anything, so the
    /// export still assembles down to an info.txt-only zip.
    static func breadcrumbFiles(in directory: URL) -> [URL] {
        let url = directory.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? [url] : []
    }

    /// The recorded lines, oldest first; empty when nothing has been recorded.
    static func lines(in directory: URL) -> [String] {
        lines(at: directory.appendingPathComponent(fileName))
    }

    /// Appends one event. Best-effort by design: a breadcrumb that cannot be
    /// written must never take down the thing it was recording.
    func record(_ event: BreadcrumbEvent, at date: Date = .now) {
        let line = ISO8601DateFormatter().string(from: date) + " " + event.text
        lock.lock()
        defer { lock.unlock() }
        try? DiagnosticsPaths.ensureExcludedDirectory(directory)
        var lines = Self.lines(at: fileURL)
        lines.append(line)
        lines = Self.capped(lines, maxBytes: maxBytes)
        try? Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: fileURL, options: .atomic)
    }

    private static func lines(at url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// Drops whole lines from the front until the trail fits. The newest line
    /// is never dropped: if it alone exceeds the cap it is truncated instead,
    /// because a cap that discards the very event being hunted is worse than
    /// one that clips it.
    private static func capped(_ lines: [String], maxBytes: Int) -> [String] {
        var lines = lines
        while lines.count > 1, byteCount(of: lines) > maxBytes {
            lines.removeFirst()
        }
        guard lines.count == 1, byteCount(of: lines) > maxBytes else { return lines }
        var only = lines[0]
        while !only.isEmpty, byteCount(of: [only]) > maxBytes {
            only.removeLast()
        }
        return [only]
    }

    /// Bytes the file will occupy: every line is written with its newline.
    private static func byteCount(of lines: [String]) -> Int {
        lines.reduce(0) { $0 + $1.utf8.count + 1 }
    }
}
