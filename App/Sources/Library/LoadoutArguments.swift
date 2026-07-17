import Foundation

enum LoadoutArgumentsError: Error, Equatable {
    case missingWAD(UUID)
}

enum LoadoutArguments {
    static func build(loadout: Loadout, resolve: (UUID) throws -> URL) throws -> [String] {
        var args = ["woof", "-iwad", try resolve(loadout.iwadID).path]

        if !loadout.pwadIDs.isEmpty {
            args.append("-file")
            for id in loadout.pwadIDs {
                args.append(try resolve(id).path)
            }
        }
        if !loadout.dehIDs.isEmpty {
            args.append("-deh")
            for id in loadout.dehIDs {
                args.append(try resolve(id).path)
            }
        }

        let saves = LibraryService.savesDirectory(forLoadoutID: loadout.id)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        args += ["-save", saves.path]

        if let complevel = loadout.complevel {
            args += ["-complevel", complevel]   // vanilla|boom|mbf|mbf21 (Woof-validated)
        }
        return args
    }
}
