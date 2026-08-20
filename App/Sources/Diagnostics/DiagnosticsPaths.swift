import Foundation

/// Where all diagnostics artifacts live. Application Support (not Documents):
/// Documents is user-visible via the Files app and doubles as the WAD adoption
/// inbox, so internal logs there would surface in the user's file browser and
/// risk being swept by the adoption pass.
enum DiagnosticsPaths {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// Metric payloads get their own subdirectory. This is the guarantee the
    /// two payload kinds need from each other: MetricKit delivers metrics
    /// roughly daily and diagnostics only when something goes wrong, so a
    /// shared retention count would evict every crash report within about
    /// `maxPayloads` days. Retention prunes by enumerating one directory, so
    /// keeping the kinds in separate ones means a metric write cannot see --
    /// let alone delete -- a diagnostic payload, without that guarantee
    /// resting on filename conventions staying disjoint.
    static func metricsDirectory(in diagnosticsDirectory: URL) -> URL {
        diagnosticsDirectory.appendingPathComponent("Metrics", isDirectory: true)
    }

    /// Creates the directory if needed and (re)applies the iCloud-backup
    /// exclusion. Application Support is backed up by default, and
    /// diagnostics leaving the device through a backup would undercut the
    /// export-only privacy story -- so every writer goes through this,
    /// reapplying the flag each time (file operations can reset it).
    static func ensureExcludedDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = url
        try? directory.setResourceValues(values)
    }
}
