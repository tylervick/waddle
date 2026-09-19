import Foundation

/// A staged change to what a game loads (spec §3.2). Rename, compat and touch
/// layout never go through here: they cannot make a save unloadable.
enum GameEdit: Equatable {
    case base(UUID?)
    case files([UUID])
}

/// The game page's decisions, pure and separate from the view for the same
/// reason `Shelf` is: the repo has no view harness, and these are the rules the
/// spec states outright.
enum GamePage {
    /// Spec §3.2: a base or file-list change on a game with saves is confirmed
    /// first, with Duplicate Instead as the default.
    static func warnsBeforeApplying(_ edit: GameEdit, saveCount: Int) -> Bool {
        saveCount > 0
    }

    /// Spec §4.2. Deliberately no "copy 2" counter — the player renames.
    static func duplicateName(for name: String) -> String {
        "\(name) copy"
    }

    /// The row label for a game's file (spec §3.2 copy).
    static func roleLabel(for file: WADFile) -> String {
        switch file.role {
        case .base: return "Base"
        case .mapSet: return "Map set"
        case .addOn: return file.kind == .deh ? "Patch" : "Add-on"
        }
    }

    /// What the Add… picker offers: every non-base file the game does not
    /// already load, in the order given.
    static func addableFiles(from all: [WADFile], to game: Game) -> [WADFile] {
        all.filter { $0.role != .base && !game.fileIDs.contains($0.id) }
    }

    /// The Delete Game confirmation's message (spec §4.4).
    static func deleteMessage(gameName: String, saveCount: Int, deletableFiles: [String]) -> String {
        var lines: [String] = []
        switch saveCount {
        case 0: lines.append("Delete \(gameName)?")
        case 1: lines.append("Delete \(gameName) and its 1 save?")
        default: lines.append("Delete \(gameName) and its \(saveCount) saves?")
        }
        switch deletableFiles.count {
        case 0: break
        case 1: lines.append("\(deletableFiles[0]) isn't used by any other game.")
        default:
            let list = deletableFiles.dropLast().joined(separator: ", ") + " and " + deletableFiles.last!
            lines.append("\(list) aren't used by any other game.")
        }
        return lines.joined(separator: "\n")
    }

    /// The Files screen's second line (spec §3.4).
    static func usedByLine(gameNames: [String]) -> String {
        gameNames.isEmpty ? "Not used by any game" : "Used by " + gameNames.joined(separator: ", ")
    }
}
