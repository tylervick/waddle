import Foundation
import WoofEngine

/// Runs Woof! engine sessions. The engine takes over the screen with its own
/// SDL window; this call blocks the main thread until the user quits (SDL
/// pumps UIKit events internally, so the app stays responsive to the system).
@MainActor
enum EngineSession {
    /// Shared capture over the app's diagnostics directory. One session log per
    /// engine run; the exporter bundles whatever this leaves behind.
    static let sessionLogCapture = SessionLogCapture(directory: DiagnosticsPaths.directory)

    /// Swift-side-only sentinel exit codes for app-layer failures that never
    /// reach the engine at all, so they can still flow through the same
    /// `EngineErrorAlert.from(exitCode:engineMessage:)` path as a real
    /// engine exit. WoofIOS_Run itself only ever returns 0 (clean) or -1
    /// (its own generic failure exit) — these values are never returned by
    /// the engine.
    enum ExitCode {
        /// LaunchArguments.build threw before the engine could even start
        /// (e.g. a game references a WAD that's gone missing from the
        /// library). Reported by ShelfView.play(_:) in place of a
        /// real engine exit code.
        static let argumentFailure: Int32 = -101

        /// play(arguments:)'s reentrancy guard fired: a session was already
        /// running when a second play() call came in.
        static let reentrant: Int32 = -102
    }

    private(set) static var isRunning = false
    private(set) static var sessionGeneration = 0

    /// Engine error text from the most recent session; nil on clean exit.
    /// Captured from the engine's errmsg buffer right after WoofIOS_Run
    /// returns (the buffer itself is reset at the next session start).
    private(set) static var lastErrorMessage: String?

    #if DEBUG
    /// Sessions started in this launch; WADDLE_TEST_DEH_SESSIONS counts them.
    private static var testSessionCount = 0
    #endif

    #if DEBUG
    /// Test-only bookkeeping hook: bumps the generation counter the same way
    /// play() does, without booting a real engine.
    static func beginSessionForTesting() { sessionGeneration += 1 }

    /// Test-only: forces the isRunning flag so play()'s reentrancy guard
    /// path is reachable without booting a real engine (the guard returns
    /// before any engine/overlay work, so calling play() under this flag
    /// is side-effect-free).
    static func setRunningForTesting(_ running: Bool) { isRunning = running }
    #endif

    /// True if `generation` (captured at the start of some session) still
    /// matches the current session. False once a later session has begun.
    static func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == sessionGeneration
    }

    /// Boots the engine with a full argv (starting with "woof") and returns
    /// the engine exit code. Build argv with LaunchArguments.
    @discardableResult
    static func play(arguments: [String],
                     scheme: TouchControlScheme = TouchControlScheme.current()) -> Int32 {
        // Defense-in-depth: never crash (ledger item). Overwrite
        // lastErrorMessage too — leaving it untouched here would pair the
        // reentrant alert with a previous session's stale error text.
        guard !isRunning else {
            lastErrorMessage = "Another session is already running."
            return ExitCode.reentrant
        }
        precondition(arguments.first == "woof", "argv[0] must be the program name")

        sessionGeneration += 1

        #if DEBUG
        let generation = sessionGeneration

        // Autoquit (UI testing): only quit the session it was armed for, so
        // a stale timer left over from a prior session can't reach into the
        // next one and quit it early. Debug builds only — release carries
        // no test seams.
        if let secondsString = ProcessInfo.processInfo
            .environment["WADDLE_AUTOQUIT_SECONDS"],
            let seconds = Double(secondsString)
        {
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: seconds)
                DispatchQueue.main.async {
                    if isCurrentGeneration(generation) && isRunning {
                        WoofIOS_RequestQuit()
                    }
                }
            }
        }
        #endif

        isRunning = true
        // Session log names are wall-clock timestamps, not the generation counter:
        // the counter restarts at 1 every launch, so generation-named files would
        // overwrite the previous launch's logs -- exactly the ones a crash report
        // needs. The random suffix keeps two sessions within the same second from
        // colliding. Failure to start capture never blocks gameplay (spec).
        let logStamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
            + "-" + String(UUID().uuidString.prefix(4))
        try? sessionLogCapture.begin(name: logStamp)
        OverlayPresenter.shared.begin(scheme: scheme)
        defer {
            OverlayPresenter.shared.end()
            sessionLogCapture.end()
            isRunning = false
        }

        var effectiveArguments = arguments
        #if DEBUG
        // Test-only (same seam family as WADDLE_AUTOQUIT_SECONDS above):
        // Woof never auto-warps into a level without an explicit -warp flag
        // (see README), so a UITest that needs in-game state -- not just
        // the title screen -- has no menu-free path there otherwise.
        if ProcessInfo.processInfo.environment["WADDLE_TEST_WARP"] != nil {
            effectiveArguments += ["-warp", "1", "-skill", "1"]
        }
        // Test-only: I_Error's own SDL message box (I_ErrorMsg) runs a modal
        // loop an XCUITest tap does not dismiss, so a test that makes the
        // engine fail on purpose turns it off; the launcher's own "Couldn't
        // run this game" alert still carries the message.
        if ProcessInfo.processInfo.environment["WADDLE_TEST_NOGUI"] != nil {
            effectiveArguments += ["-nogui"]
        }
        // Test-only (issue #270): WADDLE_TEST_DEH_TEXT is a DEHACKED patch,
        // loaded with -deh into the sessions WADDLE_TEST_DEH_SESSIONS lists
        // ("1,3": the first and third of this launch), so a test can play a
        // modded session and then check that the next one starts unmodded
        // without shipping a PWAD fixture.
        testSessionCount += 1
        let env = ProcessInfo.processInfo.environment
        if let text = env["WADDLE_TEST_DEH_TEXT"],
           (env["WADDLE_TEST_DEH_SESSIONS"] ?? "1").split(separator: ",")
               .compactMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
               .contains(testSessionCount) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("waddle-test.deh")
            if (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil {
                effectiveArguments += ["-deh", url.path]
            }
        }
        // Test-only (issue #38): WADDLE_TEST_ZIP_<n> is a base64 zip loaded
        // with -file into the n-th session of this launch, so a test can hand
        // w_zip.c a WAD inside a zip, valid or broken, without a fixture file.
        if let base64 = env["WADDLE_TEST_ZIP_\(testSessionCount)"],
           let data = Data(base64Encoded: base64) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("waddle-test-\(testSessionCount).zip")
            if (try? data.write(to: url)) != nil {
                effectiveArguments += ["-file", url.path]
            }
        }
        #endif

        var argv: [UnsafeMutablePointer<CChar>?] = effectiveArguments.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        let code = WoofIOS_Run(Int32(effectiveArguments.count), &argv)
        lastErrorMessage = code == 0 ? nil
            : String(cString: WoofIOS_LastErrorMessage())
        return code
    }
}
