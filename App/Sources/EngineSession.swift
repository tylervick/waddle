import Foundation
import WoofEngine

/// Runs Woof! engine sessions. The engine takes over the screen with its own
/// SDL window; this call blocks the main thread until the user quits (SDL
/// pumps UIKit events internally, so the app stays responsive to the system).
@MainActor
enum EngineSession {
    private(set) static var isRunning = false

    /// Boots the engine with a full argv (starting with "woof") and returns
    /// the engine exit code. Build argv with LoadoutArguments.
    @discardableResult
    static func play(arguments: [String]) -> Int32 {
        precondition(!isRunning, "engine session already running")
        precondition(arguments.first == "woof", "argv[0] must be the program name")

        // If the host asked for an auto-quit (UI testing), schedule it on a
        // background thread; WoofIOS_RequestQuit is thread-safe.
        if let secondsString = ProcessInfo.processInfo
            .environment["BOOMBOX_AUTOQUIT_SECONDS"],
            let seconds = Double(secondsString)
        {
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: seconds)
                WoofIOS_RequestQuit()
            }
        }

        isRunning = true
        defer { isRunning = false }

        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        defer { argv.forEach { free($0) } }
        return WoofIOS_Run(Int32(arguments.count), &argv)
    }
}
