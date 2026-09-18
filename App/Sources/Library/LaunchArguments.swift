import Foundation

enum LaunchArgumentsError: Error, Equatable {
    case missingWAD(UUID)
    /// The game has no base (`Game.baseID == nil`): nothing to hand `-iwad`.
    case missingBase
}

/// A file resolved for launch: where it is and what it is, so the argv builder
/// can route it to `-file` or `-deh` without a second lookup.
struct ResolvedFile {
    let url: URL
    let kind: WADKind
}

enum LaunchArguments {
    /// Builds argv from already-resolved file URLs and an explicit saves key.
    /// `loadGameSlot`, when non-nil, is an `EngineSaveSlot` value that boots
    /// straight into an existing save instead of the title screen. `nil` leaves
    /// argv exactly as it was before Continue existed.
    static func build(iwadURL: URL, saveID: UUID, pwadURLs: [URL] = [],
                      dehURLs: [URL] = [], complevel: String? = nil,
                      loadGameSlot: Int? = nil) throws -> [String] {
        var args = ["woof", "-iwad", iwadURL.path]
        if !pwadURLs.isEmpty {
            args.append("-file")
            for url in pwadURLs { args.append(url.path) }
        }
        if !dehURLs.isEmpty {
            args.append("-deh")
            for url in dehURLs { args.append(url.path) }
        }
        let saves = LibraryService.savesDirectory(forGameID: saveID)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        args += ["-save", saves.path]
        if let loadGameSlot { args += ["-loadgame", String(loadGameSlot)] }
        if let complevel { args += ["-complevel", complevel] }   // vanilla|boom|mbf|mbf21
        return args
    }

    /// argv for a `Game` (spec §2.2): the base goes to `-iwad`, and the one
    /// ordered `fileIDs` list is split by each file's kind — WADs to `-file`,
    /// patches to `-deh` — with each group keeping the list's relative order.
    /// Saves are keyed by the game's id.
    static func build(game: Game, resolve: (UUID) throws -> ResolvedFile,
                      loadGameSlot: Int? = nil) throws -> [String] {
        guard let baseID = game.baseID else { throw LaunchArgumentsError.missingBase }
        let base = try resolve(baseID)
        var pwadURLs: [URL] = []
        var dehURLs: [URL] = []
        for id in game.fileIDs {
            let file = try resolve(id)
            switch file.kind {
            case .deh: dehURLs.append(file.url)
            case .iwad, .pwad: pwadURLs.append(file.url)
            }
        }
        return try build(iwadURL: base.url, saveID: game.id, pwadURLs: pwadURLs,
                         dehURLs: dehURLs, complevel: game.complevel,
                         loadGameSlot: loadGameSlot)
    }
}
