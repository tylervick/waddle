import Foundation

enum LoadoutArgumentsError: Error, Equatable {
    case missingWAD(UUID)
}

enum LoadoutArguments {
    /// Builds argv from already-resolved file URLs and an explicit saves key.
    /// Used by the `Loadout` overload (saveID = loadout.id) and by ephemeral
    /// base-game launches (saveID = the IWAD's WADFile.id), so each base game
    /// keeps its own stable saves directory without a persisted Loadout.
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
        let saves = LibraryService.savesDirectory(forLoadoutID: saveID)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        args += ["-save", saves.path]
        if let loadGameSlot { args += ["-loadgame", String(loadGameSlot)] }
        if let complevel { args += ["-complevel", complevel] }   // vanilla|boom|mbf|mbf21
        return args
    }

    static func build(loadout: Loadout, resolve: (UUID) throws -> URL,
                      loadGameSlot: Int? = nil) throws -> [String] {
        let iwadURL = try resolve(loadout.iwadID)
        let pwadURLs = try loadout.pwadIDs.map { try resolve($0) }
        let dehURLs = try loadout.dehIDs.map { try resolve($0) }
        return try build(iwadURL: iwadURL, saveID: loadout.id,
                         pwadURLs: pwadURLs, dehURLs: dehURLs, complevel: loadout.complevel,
                         loadGameSlot: loadGameSlot)
    }
}
