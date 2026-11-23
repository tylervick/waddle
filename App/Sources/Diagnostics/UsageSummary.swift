import Foundation

/// Durable counts of how the app is used (issue #487), kept only on this
/// device and bundled into the diagnostics export the user chooses to share.
///
/// Counts only, on purpose: no timestamp finer than a day, no identifiers,
/// no paths, no file contents, and **no names**. A game's name is either an
/// imported file's title or text the user typed, and a name kept here would
/// outlive the game's deletion or renaming until Reset (review of pull
/// request 491). So sessions are bucketed: the two bundled Freedoom games by
/// their fixed names, everything else as "imported". The fields below are
/// the whole vocabulary of `usage.json`; `DiagnosticsExporterTests` and
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
        /// Foreground play time only; see `UsageSession`.
        var minutes: Double = 0

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessions = (try? c.decodeIfPresent(Int.self, forKey: .sessions)) ?? 0
            minutes = (try? c.decodeIfPresent(Double.self, forKey: .minutes)) ?? 0
        }
    }

    /// Fixed keys, never a name. A file written before the buckets existed
    /// (keyed by game name) decodes to zeros here, so the first write after
    /// an update drops every name it held.
    struct GameBuckets: Codable, Equatable {
        var freedoomPhase1 = GameCounts()
        var freedoomPhase2 = GameCounts()
        var imported = GameCounts()

        enum CodingKeys: String, CodingKey {
            case freedoomPhase1 = "freedoom_phase_1"
            case freedoomPhase2 = "freedoom_phase_2"
            case imported
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            freedoomPhase1 = (try? c.decodeIfPresent(GameCounts.self, forKey: .freedoomPhase1)) ?? GameCounts()
            freedoomPhase2 = (try? c.decodeIfPresent(GameCounts.self, forKey: .freedoomPhase2)) ?? GameCounts()
            imported = (try? c.decodeIfPresent(GameCounts.self, forKey: .imported)) ?? GameCounts()
        }

        subscript(bucket: UsageGameBucket) -> GameCounts {
            get {
                switch bucket {
                case .freedoomPhase1: return freedoomPhase1
                case .freedoomPhase2: return freedoomPhase2
                case .imported: return imported
                }
            }
            set {
                switch bucket {
                case .freedoomPhase1: freedoomPhase1 = newValue
                case .freedoomPhase2: freedoomPhase2 = newValue
                case .imported: imported = newValue
                }
            }
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
    /// Sessions the process ended in while the app was not active: flicked
    /// away in the app switcher, or reclaimed by iOS in the background. Told
    /// apart from a crash: started minus the three outcomes is what is left
    /// for crashes.
    var sessionsEndedWhileInactive = 0
    /// Active time only (`UsageSession`): a session left in the background
    /// overnight, or behind Control Center, adds nothing while it waits.
    var playMinutesTotal: Double = 0
    var sessionsByControlScheme = ControlSchemeCounts()
    var sessionsByOrientation = OrientationCounts()
    var sessionsByGame = GameBuckets()
    var wadsImported = 0
    var gamesCreated = 0
    /// Export Diagnostics share sheets the user completed. Counted when the
    /// sheet reports completion, so a cancelled share is not counted, and a
    /// file never counts its own share. A feedback email (issue #484) is not
    /// counted: the mail sheet keeps no record.
    var diagnosticsExports = 0

    /// Spelled out rather than left to a key strategy, so the file's
    /// vocabulary is visible in one place.
    enum CodingKeys: String, CodingKey {
        case firstSeenDay = "first_seen_day"
        case lastSeenDay = "last_seen_day"
        case appVersions = "app_versions"
        case launches
        case sessionsStarted = "sessions_started"
        case sessionsClean = "sessions_clean"
        case sessionsFailed = "sessions_failed"
        case sessionsEndedWhileInactive = "sessions_ended_while_inactive"
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
        sessionsEndedWhileInactive = (try? c.decodeIfPresent(
            Int.self, forKey: .sessionsEndedWhileInactive)) ?? 0
        playMinutesTotal = (try? c.decodeIfPresent(Double.self, forKey: .playMinutesTotal)) ?? 0
        sessionsByControlScheme = (try? c.decodeIfPresent(
            ControlSchemeCounts.self, forKey: .sessionsByControlScheme)) ?? ControlSchemeCounts()
        sessionsByOrientation = (try? c.decodeIfPresent(
            OrientationCounts.self, forKey: .sessionsByOrientation)) ?? OrientationCounts()
        sessionsByGame = (try? c.decodeIfPresent(
            GameBuckets.self, forKey: .sessionsByGame)) ?? GameBuckets()
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
        func game(_ counts: GameCounts) -> String {
            "\(Self.sessionsText(counts.sessions)), \(Self.minutesText(counts.minutes))"
        }
        return [
            ("First seen", firstSeenDay ?? "never"),
            ("Last seen", lastSeenDay ?? "never"),
            ("App versions", appVersions.isEmpty ? "none" : appVersions.joined(separator: ", ")),
            ("Launches", "\(launches)"),
            ("Sessions started", "\(sessionsStarted)"),
            ("Sessions ended cleanly", "\(sessionsClean)"),
            ("Sessions ended in an error", "\(sessionsFailed)"),
            ("Sessions ended while inactive", "\(sessionsEndedWhileInactive)"),
            ("Play time", Self.minutesText(playMinutesTotal)),
            ("Classic controls", Self.sessionsText(sessionsByControlScheme.classic)),
            ("Modern controls", Self.sessionsText(sessionsByControlScheme.modern)),
            ("With a game controller", Self.sessionsText(sessionsByControlScheme.gameController)),
            ("Portrait", Self.sessionsText(sessionsByOrientation.portrait)),
            ("Landscape", Self.sessionsText(sessionsByOrientation.landscape)),
            ("Freedoom Phase 1", game(sessionsByGame.freedoomPhase1)),
            ("Freedoom Phase 2", game(sessionsByGame.freedoomPhase2)),
            ("Imported games", game(sessionsByGame.imported)),
            ("WADs imported", "\(wadsImported)"),
            ("Games created", "\(gamesCreated)"),
            ("Diagnostics files shared", "\(diagnosticsExports)"),
        ]
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

/// Which bucket a session is counted in. Never a name: see `UsageSummary`.
enum UsageGameBucket: CaseIterable {
    case freedoomPhase1
    case freedoomPhase2
    case imported

    /// A game is one of the bundled Freedoom games only when it plays that
    /// bundled IWAD and nothing else; anything with a file the user brought
    /// (a map set, an add-on) or a base the user imported is "imported".
    static func of(baseFilename: String?, baseIsBundled: Bool, hasFiles: Bool) -> UsageGameBucket {
        guard baseIsBundled, !hasFiles else { return .imported }
        switch baseFilename?.lowercased() {
        case "freedoom1.wad": return .freedoomPhase1
        case "freedoom2.wad": return .freedoomPhase2
        default: return .imported
        }
    }
}

extension UsageGameBucket {
    /// The bucket `game` counts under, read from its base's row: the
    /// bundled flag and the fixed filename, never anything the user named.
    @MainActor
    static func of(_ game: Game, in library: LibraryService) -> UsageGameBucket {
        let base = game.baseID.flatMap { try? library.wad(id: $0) }
        return of(baseFilename: base?.filename, baseIsBundled: base?.isBundled ?? false,
                  hasFiles: !game.fileIDs.isEmpty)
    }
}

/// Reads and writes `usage.json` in the diagnostics directory. Nothing reads
/// the file except this store, and only the exporter and the About screen
/// read the store.
///
/// Every write happens on the main thread: at launch, around a session and
/// its active and inactive transitions, on an import or a new game, or when a share
/// completes.
final class UsageStore: @unchecked Sendable {
    static let fileName = "usage.json"
    /// Present while a session's app is not active. Seen at the next launch,
    /// it means the process ended then, not in a crash. Never exported: the
    /// exporter copies an allowlist, and this is not on it.
    static let inactiveMarkerName = "usage-session-inactive"

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
    var inactiveMarkerURL: URL { directory.appendingPathComponent(Self.inactiveMarkerName) }

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

    /// Also settles the previous process: a session it left while not
    /// active is counted as ended while inactive.
    func recordLaunch(version: String, at date: Date = .now, timeZone: TimeZone = .current) {
        let endedWhileInactive = FileManager.default.fileExists(atPath: inactiveMarkerURL.path)
        update { summary in
            Self.markSeen(&summary, at: date, timeZone: timeZone)
            if !summary.appVersions.contains(version) {
                summary.appVersions.append(version)
            }
            summary.launches += 1
            if endedWhileInactive { summary.sessionsEndedWhileInactive += 1 }
        }
        setInactive(false)
    }

    func recordSessionStart(bucket: UsageGameBucket, scheme: TouchControlScheme,
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
            summary.sessionsByGame[bucket].sessions += 1
        }
    }

    /// The app resigned active mid-session: the active time so far is saved
    /// now, so a kill from here keeps it, and the marker is set.
    func recordSessionInactive(bucket: UsageGameBucket, playTime: TimeInterval) {
        addPlayTime(playTime, to: bucket)
        setInactive(true)
    }

    /// Active again: the process did not end while inactive.
    func recordSessionActive() {
        setInactive(false)
    }

    func recordSessionEnd(bucket: UsageGameBucket, exitCode: Int32, playTime: TimeInterval,
                          at date: Date = .now, timeZone: TimeZone = .current) {
        let minutes = UsageSummary.rounded(max(0, playTime) / 60)
        update { summary in
            Self.markSeen(&summary, at: date, timeZone: timeZone)
            if exitCode == 0 {
                summary.sessionsClean += 1
            } else {
                summary.sessionsFailed += 1
            }
            Self.add(minutes, to: bucket, in: &summary)
        }
        setInactive(false)
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

    /// A share sheet holding a diagnostics file completed.
    func recordExport() {
        update { $0.diagnosticsExports += 1 }
    }

    /// Zeroes every count: the About screen's Reset Usage Counts.
    func reset() {
        update { $0 = UsageSummary() }
        setInactive(false)
    }

    private func addPlayTime(_ playTime: TimeInterval, to bucket: UsageGameBucket) {
        let minutes = UsageSummary.rounded(max(0, playTime) / 60)
        guard minutes > 0 else { return }
        update { Self.add(minutes, to: bucket, in: &$0) }
    }

    private static func add(_ minutes: Double, to bucket: UsageGameBucket,
                            in summary: inout UsageSummary) {
        summary.playMinutesTotal = UsageSummary.rounded(summary.playMinutesTotal + minutes)
        summary.sessionsByGame[bucket].minutes =
            UsageSummary.rounded(summary.sessionsByGame[bucket].minutes + minutes)
    }

    private func setInactive(_ inactive: Bool) {
        let url = inactiveMarkerURL
        if inactive {
            try? DiagnosticsPaths.ensureExcludedDirectory(directory)
            try? Data().write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
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
