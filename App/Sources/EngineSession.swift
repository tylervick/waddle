import Foundation
import WoofEngine

/// Runs Woof! engine sessions. The engine takes over the screen with its own
/// SDL window; this call blocks the main thread until the user quits (SDL
/// pumps UIKit events internally, so the app stays responsive to the system).
@MainActor
enum EngineSession {
    private(set) static var isRunning = false
    private(set) static var sessionGeneration = 0

    /// Test-only bookkeeping hook: bumps the generation counter the same way
    /// play() does, without booting a real engine.
    static func beginSessionForTesting() { sessionGeneration += 1 }

    /// True if `generation` (captured at the start of some session) still
    /// matches the current session. False once a later session has begun.
    static func isCurrentGeneration(_ generation: Int) -> Bool {
        generation == sessionGeneration
    }

    /// Boots the engine with a full argv (starting with "woof") and returns
    /// the engine exit code. Build argv with LoadoutArguments.
    @discardableResult
    static func play(arguments: [String]) -> Int32 {
        precondition(!isRunning, "engine session already running")
        precondition(arguments.first == "woof", "argv[0] must be the program name")

        sessionGeneration += 1
        let generation = sessionGeneration

        // Autoquit (UI testing): only quit the session it was armed for, so
        // a stale timer left over from a prior session can't reach into the
        // next one and quit it early.
        if let secondsString = ProcessInfo.processInfo
            .environment["BOOMBOX_AUTOQUIT_SECONDS"],
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

        isRunning = true
        OverlayPresenter.shared.begin()
        defer {
            OverlayPresenter.shared.end()
            isRunning = false
        }

        var effectiveArguments = arguments
        // Test-only (same seam family as BOOMBOX_AUTOQUIT_SECONDS above):
        // Woof never auto-warps into a level without an explicit -warp flag
        // (see README), so a UITest that needs in-game state -- not just
        // the title screen -- has no menu-free path there otherwise.
        if ProcessInfo.processInfo.environment["BOOMBOX_TEST_WARP"] != nil {
            effectiveArguments += ["-warp", "1", "-skill", "1"]
        }

        var argv: [UnsafeMutablePointer<CChar>?] = effectiveArguments.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        return WoofIOS_Run(Int32(effectiveArguments.count), &argv)
    }
}
