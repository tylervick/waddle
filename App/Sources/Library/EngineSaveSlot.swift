import Foundation

/// Maps the engine's save *filenames* onto the `-loadgame` argument that boots
/// straight into one, skipping the title screen and the Load Game menu.
///
/// Woof names a manual save `<savegamename><n>.dsg`, where `savegamename` is
/// `"%.4ssav"` of the executable's short name -- this project pins
/// `PROJECT_SHORTNAME` to `woof` (`Engine/woof/CMakeLists.txt:75`), so the
/// prefix is `woofsav` (`Engine/woof/src/d_main.c:1652`) -- and `n` is
/// `10 * page + slot` across 8 pages of 8 slots
/// (`Engine/woof/src/g_game.c:2439-2445`). `-loadgame` takes that same `n`,
/// accepting 0-77, plus the sentinel 255 for the autosave, whose filename is
/// the fixed `autosave.dsg` (`Engine/woof/src/d_main.c:2178-2194, 2417-2430`).
///
/// Autosave is on by default (`BIND_BOOL_GENERAL(autosave, true, ...)`,
/// `Engine/woof/src/g_game.c:5054`), so `autosave.dsg` is routinely the newest
/// file in a saves directory -- resuming it is what makes Continue land on the
/// level the player actually walked away from rather than their last manual
/// save.
enum EngineSaveSlot {
    /// The `-loadgame` value that loads the autosave instead of a numbered slot.
    static let autoSaveArgument = 255

    /// Not private: `LibraryService.seedContinueSaveForCapture()` writes a file
    /// under this exact name, and a second copy of the literal would be free to
    /// drift away from the one `loadGameArgument(forFilename:)` matches on —
    /// silently, since the only symptom is a Continue hero that stops rendering.
    static let autoSaveFilename = "autosave.dsg"
    private static let manualPrefix = "woofsav"
    private static let filenameSuffix = ".dsg"
    private static let highestManualArgument = 77

    /// The `-loadgame` value for one save filename, or `nil` when the name is
    /// not one the engine can load by slot. The engine lowercases the names it
    /// writes and matches pre-existing ones case-insensitively (`SaveGameName`,
    /// `Engine/woof/src/g_game.c:2415-2431`), so this does too.
    static func loadGameArgument(forFilename filename: String) -> Int? {
        let name = filename.lowercased()
        if name == autoSaveFilename { return autoSaveArgument }
        guard name.hasPrefix(manualPrefix), name.hasSuffix(filenameSuffix) else { return nil }
        let digits = name.dropFirst(manualPrefix.count).dropLast(filenameSuffix.count)
        // Round-trip instead of a bare `Int(digits)`: the engine forms these
        // with `%d`, so `woofsav07.dsg` is a name it never wrote, and folding
        // it to 7 would resume a *different* file than the one matched here.
        guard let slot = Int(digits), String(slot) == digits,
              slot >= 0, slot <= highestManualArgument else { return nil }
        return slot
    }

    /// The `-loadgame` value for the most recently modified loadable save in
    /// `slots`, or `nil` when none of them is loadable -- which covers the
    /// ordinary "no saves yet" case, where the caller launches unchanged.
    /// "Newest" is decided from `modified`, not from the argument's order, so
    /// this holds whatever order the caller happens to pass.
    static func newestLoadGameArgument(in slots: [LibraryService.SaveSlot]) -> Int? {
        slots.sorted { $0.modified > $1.modified }
            .lazy
            .compactMap { loadGameArgument(forFilename: $0.id) }
            .first
    }
}
