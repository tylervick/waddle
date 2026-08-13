import Foundation
import ZIPFoundation

/// Assembles the user-facing diagnostics zip. Pure local file assembly --
/// the result goes nowhere until the user hands it to the share sheet.
enum DiagnosticsExporter {
    /// Builds WADdle-diagnostics.zip in a fresh temp directory and returns
    /// its URL. Always succeeds down to at least an info.txt-only zip, so
    /// the share flow works even on a fresh install with nothing captured.
    static func export(diagnosticsDirectory: URL, libraryLines: [String]) throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostics-export-\(UUID().uuidString)",
                                    isDirectory: true)
        let payload = staging.appendingPathComponent("WADdle-diagnostics",
                                                     isDirectory: true)
        try FileManager.default.createDirectory(at: payload,
                                                withIntermediateDirectories: true)

        try infoText(libraryLines: libraryLines)
            .write(to: payload.appendingPathComponent("info.txt"),
                   atomically: true, encoding: .utf8)

        // Allowlist copy, not a directory copy: anything else that ever ends
        // up in the diagnostics directory (or a stray WAD) must not ship.
        let bundled = SessionLogCapture.sessionLogs(in: diagnosticsDirectory)
            + DiagnosticsStore.payloadFiles(in: diagnosticsDirectory)
        for file in bundled {
            // A failed copy fails the whole export: a silently incomplete
            // archive is worse than an alert the user can see and retry.
            try FileManager.default.copyItem(
                at: file,
                to: payload.appendingPathComponent(file.lastPathComponent))
        }

        let zipURL = staging.appendingPathComponent("WADdle-diagnostics.zip")
        try FileManager.default.zipItem(at: payload, to: zipURL,
                                        shouldKeepParent: false)
        // The uncompressed staging copy has served its purpose.
        try? FileManager.default.removeItem(at: payload)
        return zipURL
    }

    static func infoText(libraryLines: [String]) -> String {
        var model = utsname()
        uname(&model)
        let device = withUnsafeBytes(of: &model.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let bundle = Bundle.main
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        var lines = [
            "WADdle diagnostics",
            "generated: \(ISO8601DateFormatter().string(from: .now))",
            "",
            "app version: \(version) (\(buildNumber))",
            "commit: \(BuildInfo.commit) (\(BuildInfo.branch))",
            "built at: \(BuildInfo.builtAt)",
            "iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "device: \(device)",
            "",
            "library (names only; WAD contents are never exported):",
        ]
        lines += libraryLines.isEmpty ? ["(empty)"] : libraryLines
        return lines.joined(separator: "\n") + "\n"
    }
}
