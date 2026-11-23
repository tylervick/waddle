import Foundation

/// Durable counts of how the app is used (issue #487), kept only on this
/// device and bundled into the diagnostics export the user chooses to share.
///
/// Counts only, on purpose: no timestamp finer than a day, no identifiers,
/// no paths, no file contents. Game names are the one string kept, and the
/// export's library lines already carry them. The fields below are the whole
/// vocabulary of `usage.json`; `DiagnosticsExporterTests` and
/// `UsageSummaryTests` spell the allowed keys out and fail on any other, so
/// adding one is a deliberate act.
///
/// Apple: "Data that is processed only on device is not 'collected'", so
/// none of this changes the privacy label, and nothing here sends anything.
struct UsageSummary: Codable, Equatable {
    struct ControlSchemeCounts: Codable, Equatable {
        var classic = 0
        var modern = 0
        /// Sessions that began with a game controller connected, on top of
        /// whichever touch scheme was in force.
        var gameController = 0

        enum CodingKeys: String, CodingKey {
            case classic, modern
            case gameController = "game_controller"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            classic = (try? c.decodeIfPresent(Int.self, forKey: .classic)) ?? 0
            modern = (try? c.decodeIfPresent(Int.self, forKey: .modern)) ?? 0
            gameController = (try? c.decodeIfPresent(Int.self, forKey: .gameController)) ?? 0
        }
    }

    struct OrientationCounts: Codable, Equatable {
        var portrait = 0
        var landscape = 0

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            portrait = (try? c.decodeIfPresent(Int.self, forKey: .portrait)) ?? 0
            landscape = (try? c.decodeIfPresent(Int.self, forKey: .landscape)) ?? 0
        }
    }

    struct GameCounts: Codable, Equatable {
        var sessions = 0
        var minutes: Double = 0

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = (try? c.decodeIfPresent(Int.self, forKey: .sessions)) ?? 0
            minutes = (try? c.decodeIfPresent(Double.self, forKey: .minutes)) ?? 0
        }
    }

    /// YYYY-MM-DD, in the device's own time zone.
    var firstSeenDay: String?
    var lastSeenDay: String?
    /// "1.5 (295)", oldest first, each once.
    var appVersions: [String] = []
    var launches = 0
    var sessionsStarted = 0
    /// Engine exit 0.
    var sessionsClean = 0
    /// Any non-zero exit, including a launch that could not build its argv.
    var sessionsFailed = 0
    var playMinutesTotal: Double = 0
    var sessionsByControlScheme = ControlSchemeCounts()
    var sessionsByOrientation = OrientationCounts()
    /// Keyed by game name; a bundled game (Freedoom) under its own name.
    var sessionsByGame: [String: GameCounts] = [:]
    var wadsImported = 0
    var gamesCreated = 0
    var diagnosticsExports = 0

    /// Spelled out rather than left to a key strategy: `.convertToSnakeCase`
    /// would also rewrite the game names that key `sessions_by_game`.
    enum CodingKeys: String, CodingKey {
        case firstSeenDay = "first_seen_day"
        case lastSeenDay = "last_seen_day"
        case appVersions = "app_versions"
        case launches
        case sessionsStarted = "sessions_started"
        case sessionsClean = "sessions_clean"
        case sessionsFailed = "sessions_failed"
        case playMinutesTotal = "play_minutes_total"
        case sessionsByControlScheme = "sessions_by_control_scheme"
        case sessionsByOrientation = "sessions_by_orientation"
        case sessionsByGame = "sessions_by_game"
        case wadsImported = "wads_imported"
        case gamesCreated = "games_created"
        case diagnosticsExports = "diagnostics_exports"
    }

    init() {}

    /// Lenient: a field missing from an older or damaged file reads as zero
    /// rather than discarding every other count with it.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        firstSeenDay = try? c.decodeIfPresent(String.self, forKey: .firstSeenDay)
        lastSeenDay = try? c.decodeIfPresent(String.self, forKey: .lastSeenDay)
        appVersions = (try? c.decodeIfPresent([String].self, forKey: .appVersions)) ?? []
        launches = (try? c.decodeIfPresent(Int.self, forKey: .launches)) ?? 0
        sessionsStarted = (try? c.decodeIfPresent(Int.self, forKey: .sessionsStarted)) ?? 0
        sessionsClean = (try? c.decodeIfPresent(Int.self, forKey: .sessionsClean)) ?? 0
        sessionsFailed = (try? c.decodeIfPresent(Int.self, forKey: .sessionsFailed)) ?? 0
        playMinutesTotal = (try? c.decodeIfPresent(Double.self, forKey: .playMinutesTotal)) ?? 0
        sessionsByControlScheme = (try? c.decodeIfPresent(
            ControlSchemeCounts.self, forKey: .sessionsByControlScheme)) ?? ControlSchemeCounts()
        sessionsByOrientation = (try? c.decodeIfPresent(
            OrientationCounts.self, forKey: .sessionsByOrientation)) ?? OrientationCounts()
        sessionsByGame = (try? c.decodeIfPresent(
            [String: GameCounts].self, forKey: .sessionsByGame)) ?? [:]
        wadsImported = (try? c.decodeIfPresent(Int.self, forKey: .wadsImported)) ?? 0
        gamesCreated = (try? c.decodeIfPresent(Int.self, forKey: .gamesCreated)) ?? 0
        diagnosticsExports = (try? c.decodeIfPresent(Int.self, forKey: .diagnosticsExports)) ?? 0
    }

    /// The file's bytes: sorted keys and indentation, so a person opening the
    /// zip can read it, and two exports of the same counts are identical.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The same counts as label/value rows: info.txt's usage block and the
    /// About screen's View Usage Summary both read these, so what the user
    /// sees before exporting is what the export says.
    var rows: [(label: String, value: String)] {
        var rows: [(String, String)] = [
            ("First seen", firstSeenDay ?? "never"),
            ("Last seen", lastSeenDay ?? "never"),
            ("App versions", appVersions.isEmpty ? "none" : appVersions.joined(separator: ", ")),
            ("Launches", "\(launches)"),
            ("Sessions started", "\(sessionsStarted)"),
            ("Sessions ended cleanly", "\(sessionsClean)"),
            ("Sessions ended in an error", "\(sessionsFailed)"),
            ("Play time", Self.minutesText(playMinutesTotal)),
            ("Classic controls", Self.sessionsText(sessionsByControlScheme.classic)),
            ("Modern controls", Self.sessionsText(sessionsByControlScheme.modern)),
            ("With a game controller", Self.sessionsText(sessionsByControlScheme.gameController)),
            ("Portrait", Self.sessionsText(sessionsByOrientation.portrait)),
            ("Landscape", Self.sessionsText(sessionsByOrientation.landscape)),
        ]
        for name in sessionsByGame.keys.sorted() {
            let counts = sessionsByGame[name]!
            rows.append(("Game: \(name)",
                         "\(Self.sessionsText(counts.sessions)), \(Self.minutesText(counts.minutes))"))
        }
        rows += [
            ("WADs imported", "\(wadsImported)"),
            ("Games created", "\(gamesCreated)"),
            ("Diagnostics exports", "\(diagnosticsExports)"),
        ]
        return rows
    }

    static func sessionsText(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    static func minutesText(_ minutes: Double) -> String {
        String(format: "%.1f min", minutes)
    }

    /// One decimal place: enough to add up short sessions, and it keeps the
    /// file free of binary-fraction noise like 0.30000000000000004.
    static func rounded(_ minutes: Double) -> Double {
        (minutes * 10).rounded() / 10
    }
}

/// How the device was held when a session began.
enum UsageOrientation {
    case portrait
    case landscape
}

/// Reads and writes `usage.json` in the diagnostics directory. Nothing reads
/// the file except this store, and only the exporter and the About screen
/// read the store.
///
/// Every write happens on the main thread around a session (never from the
/// engine's), at launch, on an import or a new game, or from the exporter.
final class UsageStore: @unchecked Sendable {
    static let fileName = "usage.json"

    static let shared = UsageStore(directory: DiagnosticsPaths.directory)

    let directory: URL

    /// Process-wide, not per instance: the exporter builds its own store for
    /// the directory it was handed, and it must not interleave with the
    /// shared one's read-modify-write of the same file.
    private static let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
    }

    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// The stored counts. A missing or unreadable file is all zeros: a bad
    /// file must never fail the export it rides in.
    func summary() -> UsageSummary {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        return load()
    }

    /// Applies `change` to the stored counts and writes them back, returning
    /// what was written. Best-effort like the breadcrumb log: a count that
    /// cannot be saved must never take down the thing it was counting.
    @discardableResult
    func update(_ change: (inout UsageSummary) -> Void) -> UsageSummary {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var summary = load()
        change(&summary)
        try? DiagnosticsPaths.ensureExcludedDirectory(directory)
        if let data = try? summary.jsonData() {
            try? data.write(to: fileURL, options: .atomic)
        }
        return summary
    }

    func recordLaunch(version: String, at date: Date = .now, timeZone: TimeZone = .current) {
        update { summary in
            Self.markSeen(&summary, at: date, timeZone: timeZone)
            if !summary.appVersions.contains(version) {
                summary.appVersions.append(version)
            }
            summary.launches += 1
        }
    }

    func recordSessionStart(game: String, scheme: TouchControlScheme,
                            controllerConnected: Bool, orientation: UsageOrientation,
                            at date: Date = .now, timeZone: TimeZone = .current) {
        update { summary in
            Self.markSeen(&summary, at: date, timeZone: timeZone)
            summary.sessionsStarted += 1
            switch scheme {
            case .classic: summary.sessionsByControlScheme.classic += 1
            case .modern: summary.sessionsByControlScheme.modern += 1
            }
            if controllerConnected { summary.sessionsByControlScheme.gameController += 1 }
            switch orientation {
            case .portrait: summary.sessionsByOrientation.portrait += 1
            case .landscape: summary.sessionsByOrientation.landscape += 1
            }
            summary.sessionsByGame[game, default: .init()].sessions += 1
        }
    }

    func recordSessionEnd(game: String, exitCode: Int32, duration: TimeInterval,
                          at date: Date = .now, timeZone: TimeZone = .current) {
        let minutes = UsageSummary.rounded(max(0, duration) / 60)
        update { summary in
            Self.markSeen(&summary, at: date, timeZone: timeZone)
            if exitCode == 0 {
                summary.sessionsClean += 1
            } else {
                summary.sessionsFailed += 1
            }
            summary.playMinutesTotal = UsageSummary.rounded(summary.playMinutesTotal + minutes)
            var counts = summary.sessionsByGame[game, default: .init()]
            counts.minutes = UsageSummary.rounded(counts.minutes + minutes)
            summary.sessionsByGame[game] = counts
        }
    }

    /// Counts what an import added: files, and the games they became.
    func recordImport(_ outcome: ImportOutcome) {
        guard !outcome.imported.isEmpty || !outcome.games.isEmpty else { return }
        update { summary in
            summary.wadsImported += outcome.imported.count
            summary.gamesCreated += outcome.games.count
        }
    }

    func recordGameCreated() {
        update { $0.gamesCreated += 1 }
    }

    @discardableResult
    func recordExport() -> UsageSummary {
        update { $0.diagnosticsExports += 1 }
    }

    /// Zeroes every count: the About screen's Reset Usage Counts.
    func reset() {
        update { $0 = UsageSummary() }
    }

    private func load() -> UsageSummary {
        guard let data = try? Data(contentsOf: fileURL),
              let summary = try? JSONDecoder().decode(UsageSummary.self, from: data)
        else { return UsageSummary() }
        return summary
    }

    private static func markSeen(_ summary: inout UsageSummary, at date: Date, timeZone: TimeZone) {
        let day = dayString(date, timeZone: timeZone)
        if summary.firstSeenDay == nil { summary.firstSeenDay = day }
        summary.lastSeenDay = day
    }

    /// YYYY-MM-DD and nothing finer: a day is the most precise time the file
    /// keeps.
    static func dayString(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "1.5 (295)": the same form info.txt gives the running version.
    static func currentAppVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
