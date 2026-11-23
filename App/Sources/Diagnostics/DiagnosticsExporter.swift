import Foundation
import ZIPFoundation

/// Assembles the user-facing diagnostics zip. Pure local file assembly --
/// the result goes nowhere until the user hands it to the share sheet.
enum DiagnosticsExporter {
    /// Builds Waddle-diagnostics.zip in a fresh temp directory and returns
    /// its URL. Always succeeds down to at least an info.txt-only zip, so
    /// the share flow works even on a fresh install with nothing captured.
    static func export(diagnosticsDirectory: URL, libraryLines: [String]) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-export-\(UUID().uuidString)",
                                    isDirectory: true)
        let payload = staging.appendingPathComponent("Waddle-diagnostics",
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: payload,
                                                withIntermediateDirectories: true)

        // This export is counted before the summary is read, so the file the
        // user shares says how many times they have shared one, this time
        // included. Written from the summary in hand rather than copied: a
        // missing or unreadable usage file is zeros here, never a failure.
        let usage = UsageStore(directory: diagnosticsDirectory).recordExport()
        try usage.jsonData()
            .write(to: payload.appendingPathComponent(UsageStore.fileName))

        try infoText(libraryLines: libraryLines, usage: usage)
            .write(to: payload.appendingPathComponent("info.txt"),
                   atomically: true, encoding: .utf8)

        // Allowlist copy, not a directory copy: anything else that ever ends
        // up in the diagnostics directory (or a stray WAD) must not ship.
        // Metric payloads live one directory down and carry their own prefix,
        // so they need their own entry here rather than arriving for free.
        let bundled = SessionLogCapture.sessionLogs(in: diagnosticsDirectory)
            + DiagnosticsStore.payloadFiles(in: diagnosticsDirectory)
            + DiagnosticsStore.metricPayloadFiles(in: diagnosticsDirectory)
            + BreadcrumbLog.breadcrumbFiles(in: diagnosticsDirectory)
        for file in bundled {
            // A failed copy fails the whole export: a silently incomplete
            // archive is worse than an alert the user can see and retry.
            try FileManager.default.copyItem(
                at: file,
                to: payload.appendingPathComponent(file.lastPathComponent))
        }

        let zipURL = staging.appendingPathComponent("Waddle-diagnostics.zip")
        try FileManager.default.zipItem(at: payload, to: zipURL,
                                        shouldKeepParent: false)
        // The uncompressed staging copy has served its purpose.
        try? FileManager.default.removeItem(at: payload)
        return zipURL
    }

    /// Names-only library summary for info.txt. Best-effort: a SwiftData read
    /// failure yields fewer lines, never a failed export.
    @MainActor
    static func libraryLines(from library: LibraryService?) -> [String] {
        guard let library else { return [] }
        let wads = ((try? library.allWADs()) ?? []).map { "wad: \($0.filename)" }
        let games = ((try? library.games()) ?? []).map { "game: \($0.name)" }
        return wads + games
    }

    /// Sweeps abandoned export staging directories from prior runs. Age-gated
    /// rather than "delete the immediately-previous export": share sheets
    /// (AirDrop, Save to Files) can signal sheet dismissal before the
    /// receiving side has finished reading the source file, so deleting the
    /// previous export on every new one can race an in-flight share and
    /// silently corrupt it. An hour-old export directory cannot plausibly
    /// still be streaming, and anything fresher is left for the OS's own
    /// temp-directory sweeper.
    static func reclaimStaleExports(in tempDirectory: URL = FileManager.default.temporaryDirectory,
                                    olderThan age: TimeInterval = 3600,
                                    now: Date = .now) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: tempDirectory, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("diagnostics-export-") {
            guard let modified = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { continue }
            if now.timeIntervalSince(modified) > age {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// `usage`, when given, is rendered as a block after the library: the
    /// same rows the About screen shows under View Usage Summary.
    static func infoText(libraryLines: [String], usage: UsageSummary? = nil) -> String {
        // Shared with the bug-report form and the feedback email (issue
        // #484), so the three cannot drift apart.
        let facts = DeviceFacts.current

        var lines = [
            "Waddle diagnostics",
            "generated: \(ISO8601DateFormatter().string(from: .now))",
            "",
            "app version: \(facts.appVersion)",
            "commit: \(BuildInfo.commit) (\(BuildInfo.branch))",
            "built at: \(BuildInfo.builtAt)",
            "iOS: \(facts.iosVersion)",
            "device: \(facts.device)",
            "",
            "library (names only; WAD contents are never exported):",
        ]
        lines += libraryLines.isEmpty ? ["(empty)"] : libraryLines
        if let usage {
            lines += ["", "usage (counts kept only on this device; also in \(UsageStore.fileName)):"]
            lines += usage.rows.map { "\($0.label): \($0.value)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
