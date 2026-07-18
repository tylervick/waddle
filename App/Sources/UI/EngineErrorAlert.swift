import Foundation

/// Maps an engine exit into user-facing alert content (spec §5: show the
/// engine's actual error text, plus a hint when it smells like a wrong-IWAD
/// pairing; a bad WAD must never crash the app).
struct EngineErrorAlert: Equatable {
    let title: String
    let engineMessage: String
    let hint: String?

    static func from(exitCode: Int32, engineMessage: String?) -> EngineErrorAlert? {
        guard exitCode != 0 else { return nil }
        let message = (engineMessage?.isEmpty == false)
            ? engineMessage!
            : "The engine reported no details (exit code \(exitCode))."
        return EngineErrorAlert(title: "Couldn't run this loadout",
                                engineMessage: message,
                                hint: hint(for: message))
    }

    private static func hint(for message: String) -> String? {
        let wrongIWADMarkers = ["W_GetNumForName", "not found", "Unknown or invalid IWAD"]
        if wrongIWADMarkers.contains(where: message.contains) {
            if message.contains("IWAD") {
                return "The base game file wasn't recognized. Pick a supported IWAD (Doom, Doom II, Freedoom…) for this loadout."
            }
            return "This usually means the WAD needs a different base game (IWAD). Try pairing it with Doom II / Freedoom Phase 2."
        }
        return nil
    }
}
