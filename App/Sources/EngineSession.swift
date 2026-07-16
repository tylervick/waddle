import Foundation
import WoofEngine

/// Runs Woof! engine sessions. The engine takes over the screen with its own
/// SDL window; this call blocks the main thread until the user quits (SDL
/// pumps UIKit events internally, so the app stays responsive to the system).
@MainActor
enum EngineSession {
    private(set) static var isRunning = false

    /// Boots the engine with the given IWAD (a filename inside the app
    /// bundle's GameData resources) and returns the engine exit code.
    @discardableResult
    static func play(iwad: String, extraArgs: [String] = []) -> Int32 {
        precondition(!isRunning, "engine session already running")
        guard let gameData = Bundle.main.resourceURL?
            .appendingPathComponent("GameData", isDirectory: true),
            FileManager.default.fileExists(
                atPath: gameData.appendingPathComponent(iwad).path)
        else {
            assertionFailure("missing bundled IWAD \(iwad)")
            return -100
        }

        let saves = URL.documentsDirectory
            .appendingPathComponent("Saves", isDirectory: true)
            .appendingPathComponent((iwad as NSString).deletingPathExtension,
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: saves, withIntermediateDirectories: true)

        var arguments = [
            "woof",
            "-iwad", gameData.appendingPathComponent(iwad).path,
            "-save", saves.path,
        ]
        arguments += extraArgs

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
