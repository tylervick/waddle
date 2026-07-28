import Foundation
import SwiftData

enum LibraryError: Error, Equatable {
    case wadReferencedByLoadouts([String])
}

/// Where a library file's bytes live, from the Library tab's point of view:
/// shipped read-only in the app bundle, imported into Documents/WADs/, or a
/// DB row whose backing file has vanished from disk (deleted out-of-band).
enum LibraryFileStatus: Equatable {
    case bundled
    case imported
    case missing
}

/// One Library-tab section: all files of a single kind, display-ordered.
struct LibraryGroup: Identifiable {
    let kind: WADKind
    let title: String
    let wads: [WADFile]
    var id: String { kind.rawValue }
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
    /// GameData/) as directly-playable base games. Safe to call every launch.
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
        }
        try context.save()
    }

    /// One-time migration: earlier builds auto-created a Loadout per bundled
    /// Freedoom phase so the base game could launch. Base games are now
    /// directly playable, so these phantom loadouts are removed once; any saves
    /// they accumulated migrate to the base game's own saves key (its
    /// WADFile.id), so on-device progress survives. User-authored presets are
    /// never touched.
    ///
    /// Guarded by a persisted flag so this runs at most once per install: the
    /// one-door preset flow now auto-names a modless Freedoom preset exactly
    /// "Freedoom Phase 1"/"Freedoom Phase 2", which is indistinguishable from
    /// the legacy phantom shape (no PWAD/DEH, bundled IWAD) this removes.
    ///
    /// Two safeguards against destroying real user data:
    /// - **Ambiguity:** a legacy install created *exactly one* phantom per
    ///   phase, so only a lone match for a seeded title is treated as a
    ///   phantom. If two+ loadouts share the shape (e.g. the user also made
    ///   their own "Freedoom Phase 1"), none are touched.
    /// - **Atomicity:** a loadout is deleted only after its saves migrate
    ///   successfully; `migrateSaves` merges into an existing base-game saves
    ///   dir without clobbering, and throws on any failure so the caller keeps
    ///   the loadout (and retries next launch) rather than orphaning saves.
    /// The flag is set only when every migration succeeded.
    func reconcileBundledBaseGameLoadouts(defaults: UserDefaults = .standard) throws {
        let flagKey = "didReconcileBundledBaseGameLoadouts"
        guard !defaults.bool(forKey: flagKey) else { return }
        let seededTitles: Set<String> = ["Freedoom Phase 1", "Freedoom Phase 2"]

        // Candidates: modless loadouts with a seeded title on a *bundled* IWAD.
        var phantoms: [Loadout] = []
        for loadout in try context.fetch(FetchDescriptor<Loadout>())
        where loadout.pwadIDs.isEmpty && loadout.dehIDs.isEmpty
            && seededTitles.contains(loadout.name) {
            if let iwad = try wad(id: loadout.iwadID), iwad.isBundled {
                phantoms.append(loadout)
            }
        }
        // Ambiguity guard: only delete a title with a single matching loadout.
        var countByName: [String: Int] = [:]
        for p in phantoms { countByName[p.name, default: 0] += 1 }

        var allMigrationsSucceeded = true
        for loadout in phantoms where countByName[loadout.name] == 1 {
            do {
                try migrateSaves(fromKey: loadout.id, toKey: loadout.iwadID)
                context.delete(loadout)
            } catch {
                // Keep the loadout so its saves aren't orphaned; leaving the
                // flag unset makes reconciliation retry on the next launch.
                allMigrationsSucceeded = false
            }
        }
        try context.save()
        if allMigrationsSucceeded { defaults.set(true, forKey: flagKey) }
    }

    /// Moves the legacy per-loadout saves dir onto the base game's saves key.
    /// If the destination already exists, merges file-by-file and never
    /// overwrites an existing base-game save (its version wins; the stale
    /// duplicate is left in place, not deleted). Throws on any filesystem
    /// failure so the caller can keep the loadout instead of orphaning saves.
    private func migrateSaves(fromKey old: UUID, toKey new: UUID) throws {
        let fm = FileManager.default
        let src = Self.savesDirectory(forLoadoutID: old)
        let dst = Self.savesDirectory(forLoadoutID: new)
        guard fm.fileExists(atPath: src.path) else { return }   // nothing to migrate

        if !fm.fileExists(atPath: dst.path) {
            try fm.createDirectory(at: dst.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: src, to: dst)
            return
        }
        // Destination exists (e.g. the base game was played before migration):
        // merge non-colliding entries; keep the base game's existing saves.
        for entry in try fm.contentsOfDirectory(atPath: src.path) {
            let to = dst.appendingPathComponent(entry)
            guard !fm.fileExists(atPath: to.path) else { continue }
            try fm.moveItem(at: src.appendingPathComponent(entry), to: to)
        }
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

    private func wadByFilename(_ filename: String, bundled: Bool) throws -> WADFile? {
        var descriptor = FetchDescriptor<WADFile>(
            predicate: #Predicate { $0.filename == filename && $0.isBundled == bundled })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The Library tab's file inventory: every registered file grouped by kind
    /// in fixed display order (Base Games / Mods / Patches), empty kinds
    /// omitted, each group sorted bundled-first then by filename.
    func libraryGroups() throws -> [LibraryGroup] {
        let all = try allWADs()
        let sections: [(WADKind, String)] = [(.iwad, "Base Games"), (.pwad, "Mods"), (.deh, "Patches")]
        return sections.compactMap { kind, title in
            let members = all
                .filter { $0.kindRaw == kind.rawValue }
                .sorted { ($0.isBundled ? 0 : 1, $0.filename.lowercased())
                        < ($1.isBundled ? 0 : 1, $1.filename.lowercased()) }
            return members.isEmpty ? nil : LibraryGroup(kind: kind, title: title, wads: members)
        }
    }

    func fileStatus(for wad: WADFile) -> LibraryFileStatus {
        if wad.isBundled { return .bundled }
        return FileManager.default.fileExists(atPath: fileURL(for: wad).path)
            ? .imported : .missing
    }

    /// On-disk size of the file backing `wad`; nil when the file is missing.
    func fileSize(for wad: WADFile) -> Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL(for: wad).path)
        return (attrs?[.size] as? NSNumber)?.int64Value
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
