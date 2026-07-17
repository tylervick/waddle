import Foundation
import SwiftData

enum LibraryError: Error, Equatable {
    case wadReferencedByLoadouts([String])
}

@MainActor
final class LibraryService {
    private let context: ModelContext
    private let store: WADStore

    init(context: ModelContext, store: WADStore) {
        self.context = context
        self.store = store
    }

    // MARK: Seeding

    /// Registers the bundled Freedoom IWADs (read-only, live in the bundle's
    /// GameData/) and creates one loadout per phase. Safe to call every launch.
    func seedBundledContentIfNeeded() throws {
        let bundled: [(file: String, title: String, family: GameFamily)] = [
            ("freedoom1.wad", "Freedoom Phase 1", .doom1),
            ("freedoom2.wad", "Freedoom Phase 2", .doom2),
        ]
        for entry in bundled {
            if try wadByFilename(entry.file, bundled: true) != nil { continue }
            let wad = WADFile(filename: entry.file, displayName: entry.title,
                              kindRaw: WADKind.iwad.rawValue, sha1: "bundled:\(entry.file)",
                              gameFamilyRaw: entry.family.rawValue, isBundled: true)
            context.insert(wad)
            context.insert(Loadout(name: entry.title, iwadID: wad.id))
        }
        try context.save()
    }

    // MARK: Queries

    func allWADs() throws -> [WADFile] {
        try context.fetch(FetchDescriptor<WADFile>(
            sortBy: [SortDescriptor(\.importDate, order: .reverse)]))
    }

    func allLoadouts() throws -> [Loadout] {
        try context.fetch(FetchDescriptor<Loadout>()).sorted {
            ($0.lastPlayed ?? $0.createdAt) > ($1.lastPlayed ?? $1.createdAt)
        }
    }

    func wad(id: UUID) throws -> WADFile? {
        var descriptor = FetchDescriptor<WADFile>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func findWAD(sha1: String) throws -> WADFile? {
        var descriptor = FetchDescriptor<WADFile>(predicate: #Predicate { $0.sha1 == sha1 })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func wadByFilename(_ filename: String, bundled: Bool) throws -> WADFile? {
        var descriptor = FetchDescriptor<WADFile>(
            predicate: #Predicate { $0.filename == filename && $0.isBundled == bundled })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Mutations

    @discardableResult
    func registerImported(filename: String, sha1: String, kind: String,
                          family: String) throws -> WADFile {
        let wad = WADFile(filename: filename,
                          displayName: (filename as NSString).deletingPathExtension,
                          kindRaw: kind, sha1: sha1, gameFamilyRaw: family)
        context.insert(wad)
        try context.save()
        return wad
    }

    /// Points an existing row at a freshly re-stored file, for when the row's
    /// backing file went missing from disk (e.g. deleted out-of-band) and a
    /// re-import restored the content under a new store filename.
    func repairFilename(of wad: WADFile, to filename: String) throws {
        wad.filename = filename
        try context.save()
    }

    @discardableResult
    func createLoadout(name: String, iwadID: UUID, pwadIDs: [UUID],
                       dehIDs: [UUID]) throws -> Loadout {
        let loadout = Loadout(name: name, iwadID: iwadID, pwadIDs: pwadIDs, dehIDs: dehIDs)
        context.insert(loadout)
        try context.save()
        return loadout
    }

    /// Persists in-place mutations made directly to fetched/created model
    /// instances (e.g. editing an existing Loadout's fields, or bumping
    /// lastPlayed) — those mutations aren't saved on their own; SwiftData's
    /// autosave is not immediate/guaranteed at the point callers need it.
    func saveChanges() throws {
        try context.save()
    }

    func loadoutsReferencing(wadID: UUID) throws -> [Loadout] {
        try context.fetch(FetchDescriptor<Loadout>()).filter {
            $0.iwadID == wadID || $0.pwadIDs.contains(wadID) || $0.dehIDs.contains(wadID)
        }
    }

    func deleteWAD(_ wad: WADFile, force: Bool) throws {
        let referencing = try loadoutsReferencing(wadID: wad.id)
        if !referencing.isEmpty && !force {
            throw LibraryError.wadReferencedByLoadouts(referencing.map(\.name))
        }
        if !wad.isBundled {
            try? store.delete(filename: wad.filename)
        }
        context.delete(wad)
        try context.save()
    }

    func deleteLoadout(_ loadout: Loadout, deleteSaves: Bool) throws {
        if deleteSaves {
            try? FileManager.default.removeItem(
                at: Self.savesDirectory(forLoadoutID: loadout.id))
        }
        context.delete(loadout)
        try context.save()
    }

    // MARK: Paths

    func fileURL(for wad: WADFile) -> URL {
        if wad.isBundled {
            return Bundle.main.resourceURL!
                .appendingPathComponent("GameData", isDirectory: true)
                .appendingPathComponent(wad.filename)
        }
        return store.url(forFilename: wad.filename)
    }

    nonisolated static func savesDirectory(forLoadoutID id: UUID) -> URL {
        URL.documentsDirectory
            .appendingPathComponent("Saves", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
