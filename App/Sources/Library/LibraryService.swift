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

    /// Base games (IWADs) for the Play grid — bundled first, then by title.
    func baseGames() throws -> [WADFile] {
        try allWADs()
            .filter { $0.kindRaw == WADKind.iwad.rawValue }
            .sorted { ($0.isBundled ? 0 : 1, $0.displayName) < ($1.isBundled ? 0 : 1, $1.displayName) }
    }

    /// Base games + presets that have been played, most-recent-first, capped.
    func recentlyPlayed(limit: Int) throws -> [PlayableItem] {
        let items = try baseGames().map(PlayableItem.baseGame)
            + allLoadouts().map(PlayableItem.preset)
        return items
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

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

    /// Best-guess IWAD for a PWAD (spec §4 "New loadout with [detected IWAD]"):
    /// a user-imported IWAD of the same family wins; bundled Freedoom is the
    /// always-available fallback (doom1 -> phase 1, everything else -> phase 2).
    func suggestedIWAD(for pwad: WADFile) throws -> WADFile? {
        let iwads = try allWADs().filter { $0.kindRaw == WADKind.iwad.rawValue }
        if let match = iwads.first(where: {
            !$0.isBundled && $0.gameFamilyRaw == pwad.gameFamilyRaw
        }) {
            return match
        }
        let fallback = pwad.gameFamilyRaw == GameFamily.doom1.rawValue
            ? "freedoom1.wad" : "freedoom2.wad"
        return iwads.first { $0.isBundled && $0.filename == fallback }
    }

    private func wadByFilename(_ filename: String, bundled: Bool) throws -> WADFile? {
        var descriptor = FetchDescriptor<WADFile>(
            predicate: #Predicate { $0.filename == filename && $0.isBundled == bundled })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: Mutations

    /// Stamps a directly-played WAD's `lastPlayed` (base games launch without
    /// a persisted Loadout, so recency is tracked on the file itself). Date is
    /// injectable for deterministic tests.
    func markPlayed(_ wad: WADFile, at date: Date = .now) throws {
        wad.lastPlayed = date
        try context.save()
    }

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

    /// Sets (or clears, with `nil`) a base game's per-item touch-scheme
    /// override. `PlayableDetailView`'s Controls picker writes through here
    /// for a `.baseGame` item.
    func setSchemeOverride(_ raw: String?, forBaseGame wad: WADFile) throws {
        wad.schemeOverrideRaw = raw
        try saveChanges()
    }

    /// Sets (or clears, with `nil`) a preset's per-item touch-scheme
    /// override. `PlayableDetailView`'s Controls picker writes through here
    /// for a `.preset` item.
    func setSchemeOverride(_ raw: String?, forPreset loadout: Loadout) throws {
        loadout.schemeOverrideRaw = raw
        try saveChanges()
    }

    // MARK: Saves

    /// A single visible save file in a playable item's saves directory (see
    /// `savesDirectory(forLoadoutID:)`); `id` is the filename.
    struct SaveSlot: Identifiable, Equatable {
        let id: String
        let modified: Date
    }

    /// Lists the save files for a playable item's saves key (base game ->
    /// `wad.id`, preset -> `loadout.id`), newest-modified first. Empty (not
    /// throwing) if the directory is missing or unreadable -- a brand new
    /// item simply has no saves yet.
    func saveSlots(forKey id: UUID) -> [SaveSlot] {
        let dir = Self.savesDirectory(forLoadoutID: id)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return files
            .compactMap { url -> SaveSlot? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                      let modified = values.contentModificationDate else { return nil }
                return SaveSlot(id: url.lastPathComponent, modified: modified)
            }
            .sorted { $0.modified > $1.modified }
    }

    /// Deletes one save file for a playable item's saves key. Best-effort --
    /// a missing file is not an error.
    func deleteSave(_ slot: SaveSlot, forKey id: UUID) {
        try? FileManager.default.removeItem(
            at: Self.savesDirectory(forLoadoutID: id).appendingPathComponent(slot.id))
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
