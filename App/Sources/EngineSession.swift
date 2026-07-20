import Foundation
import WoofEngine

/// Runs Woof! engine sessions. The engine takes over the screen with its own
/// SDL window; this call blocks the main thread until the user quits (SDL
/// pumps UIKit events internally, so the app stays responsive to the system).
@MainActor
enum EngineSession {
    /// Swift-side-only sentinel exit codes for app-layer failures that never
    /// reach the engine at all, so they can still flow through the same
    /// `EngineErrorAlert.from(exitCode:engineMessage:)` path as a real
    /// engine exit. WoofIOS_Run itself only ever returns 0 (clean) or -1
    /// (its own generic failure exit) — these values are never returned by
    /// the engine.
    enum ExitCode {
        /// LoadoutArguments.build threw before the engine could even start
        /// (e.g. a loadout references a WAD that's gone missing from the
        /// library). Reported by LoadoutGridView.play(_:) in place of a
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
    /// the engine exit code. Build argv with LoadoutArguments.
    @discardableResult
    static func play(arguments: [String]) -> Int32 {
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
        OverlayPresenter.shared.begin()
        defer {
            OverlayPresenter.shared.end()
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
        #endif

        var argv: [UnsafeMutablePointer<CChar>?] = effectiveArguments.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        let code = WoofIOS_Run(Int32(effectiveArguments.count), &argv)
        lastErrorMessage = code == 0 ? nil
            : String(cString: WoofIOS_LastErrorMessage())
        return code
    }
}
