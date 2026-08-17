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

    /// Resolves an imported file's content SHA-1 to a published game title, or
    /// nil when the content isn't a recognized commercial IWAD.
    ///
    /// Injectable seam for tests only: production always resolves against the
    /// shipped `IWADCatalog`. The repository ships no commercial WAD content
    /// (and never will), so this is the only way a test can drive the *import
    /// path* end-to-end for a recognized file — it registers a synthetic
    /// fixture's own hash and imports that. Same pattern, and the same reason,
    /// as `ImportService.maxZipEntryBytes`.
    var recognizedTitle: (String) -> String? = IWADCatalog.title(forSHA1:)

    init(context: ModelContext, store: WADStore) {
        self.context = context
        self.store = store
    }

    // MARK: Seeding

    /// Registers the bundled Freedoom IWADs (read-only, live in the bundle's
    /// GameData/) as directly-playable base games. Safe to call every launch:
    /// each row stores its real content SHA-1 (so imports of byte-identical
    /// files dedupe against it), but the hash is computed only the one time
    /// the row is created — steady-state launches skip straight past the
    /// existence check and never re-hash the ~30MB bundle files.
    func seedBundledContentIfNeeded() throws {
        let bundled: [(file: String, title: String, family: GameFamily)] = [
            ("freedoom1.wad", "Freedoom Phase 1", .doom1),
            ("freedoom2.wad", "Freedoom Phase 2", .doom2),
        ]
        for entry in bundled {
            // Presence only — never filter this on `isHidden`. A hidden row is
            // present, just off the shelf; treating it as missing would insert a
            // duplicate under a fresh UUID and orphan Documents/Saves/<id>/,
            // which is exactly what spec §4 made hiding reversible to avoid.
            // Pinned by `testSeederTreatsHiddenBundledRowAsPresent`.
            if try wadByFilename(entry.file, bundled: true) != nil { continue }
            let wad = WADFile(filename: entry.file, displayName: entry.title,
                              kindRaw: WADKind.iwad.rawValue,
                              sha1: try WADStore.sha1(ofFileAt: Self.bundledURL(forFilename: entry.file)),
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

    /// Base games (IWADs) on the Play shelf — bundled first, then by title.
    /// Excludes hidden rows, so a base game the player removed from the shelf
    /// is offered nowhere it could be started from (this feeds the preset
    /// builder's IWAD picker too). Presets already built on a hidden base game
    /// keep working: the launcher resolves their IWAD by id, not through here.
    func baseGames() throws -> [WADFile] {
        try baseGames(hidden: false)
    }

    private func baseGames(hidden: Bool) throws -> [WADFile] {
        try allWADs()
            .filter { $0.kindRaw == WADKind.iwad.rawValue && $0.isHidden == hidden }
            .sorted { ($0.isBundled ? 0 : 1, $0.displayName) < ($1.isBundled ? 0 : 1, $1.displayName) }
    }

    /// Base games + presets that have been played, most-recent-first, capped.
    func recentlyPlayed(limit: Int) throws -> [PlayableItem] {
        let items = try baseGames().map(PlayableItem.baseGame)
            + presets().map(PlayableItem.preset)
        return items
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// Presets on the Play shelf, in `allLoadouts()`' order minus hidden rows.
    /// `allLoadouts()` deliberately still reports every preset — it backs the
    /// Library inventory and the diagnostics dump, neither of which is a shelf.
    func presets() throws -> [Loadout] {
        try allLoadouts().filter { !$0.isHidden }
    }

    /// Everything the shelf shows, unordered: base games and presets mixed, with
    /// hidden rows already excluded by `baseGames()`/`presets()`. `ShelfView`
    /// reads exactly this and then hands it to `Shelf.ordered` — so "a hidden
    /// item never reaches the shelf" is a property of this one call rather than
    /// of a filter the view could forget to apply.
    func shelfItems() throws -> [PlayableItem] {
        try baseGames().map(PlayableItem.baseGame) + presets().map(PlayableItem.preset)
    }

    /// Everything the player has taken off the shelf, for Manage → Hidden from
    /// Shelf. Base games first, then presets, each in its shelf order.
    func hiddenItems() throws -> [PlayableItem] {
        try baseGames(hidden: true).map(PlayableItem.baseGame)
            + allLoadouts().filter(\.isHidden).map(PlayableItem.preset)
    }

    /// True while the library is still exactly what the app shipped with:
    /// nothing imported, no presets, and nothing saved anywhere. This is spec
    /// §4's factory state, and the only condition under which the shelf shows
    /// its welcome card -- once any of the three stops holding, it never holds
    /// again, so the card does not come back.
    ///
    /// Two deliberate choices about what counts:
    ///
    /// - It asks the *whole* library, not `shelfItems()`. A mod arriving by
    ///   share sheet is never a shelf item and a hidden row is not one either,
    ///   but both mean somebody's own files are in here, and greeting them as a
    ///   new arrival afterwards would be wrong.
    /// - "Any save" means any file in any item's saves directory, not a
    ///   *resumable* one. The Continue hero is strict about that distinction
    ///   (`PlayableLauncher.continuableSlot`) because it offers to boot the
    ///   save; this only asks whether the player has got as far as playing, and
    ///   a save the engine cannot resume still answers that yes.
    func isFactoryState() throws -> Bool {
        let wads = try allWADs()
        guard !wads.contains(where: { !$0.isBundled }) else { return false }
        guard try allLoadouts().isEmpty else { return false }
        // Both guards held, so the bundled rows are the whole library and
        // theirs are the only saves directories that can be in play.
        return !wads.contains { !saveSlots(forKey: $0.id).isEmpty }
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
        // Content-derived title first, filename only as a fallback: a
        // recognized commercial IWAD is titled by what it *is*, so renaming
        // doom2.wad before importing it cannot change what the Play tab calls
        // it. Anything unrecognized — every PWAD, every mod — keeps the
        // filename behavior this line has always had.
        let wad = WADFile(filename: filename,
                          displayName: recognizedTitle(sha1)
                              ?? (filename as NSString).deletingPathExtension,
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

    /// Removes a playable item from the shelf without destroying anything:
    /// the row, its backing file and its saves all stay put. Reversible with
    /// `restore(_:)`; hidden items are enumerated by `hiddenItems()`.
    func hide(_ item: PlayableItem) throws {
        try setHidden(true, on: item)
    }

    /// Puts a hidden item back on the shelf.
    func restore(_ item: PlayableItem) throws {
        try setHidden(false, on: item)
    }

    private func setHidden(_ hidden: Bool, on item: PlayableItem) throws {
        switch item {
        case .baseGame(let wad): wad.isHidden = hidden
        case .preset(let loadout): loadout.isHidden = hidden
        }
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
            return Self.bundledURL(forFilename: wad.filename)
        }
        return store.url(forFilename: wad.filename)
    }

    private static func bundledURL(forFilename filename: String) -> URL {
        Bundle.main.resourceURL!
            .appendingPathComponent("GameData", isDirectory: true)
            .appendingPathComponent(filename)
    }

    #if DEBUG
    /// Test-only: gives the most-recently-played item a save file so the
    /// shelf's Continue hero renders, for App Store screenshot capture.
    /// Driven by `WADDLE_SEED_CONTINUE_SAVE` (see `WADdleApp`).
    ///
    /// **This writes a marker, not a loadable savegame**, and that is a
    /// deliberate limit rather than an oversight. Only the engine can produce a
    /// real `.dsg`, and it writes one solely on level completion
    /// (`Engine/woof/src/g_game.c:2002`), which a warped capture session never
    /// reaches. What the hero actually depends on is
    /// `EngineSaveSlot.newestLoadGameArgument`, which resolves a slot from the
    /// *filename* alone — so `autosave.dsg` is enough to render the hero, and
    /// tapping Continue on this seeded state would not resume anything.
    ///
    /// The capture test asserts the hero is present after setting this, so if
    /// that filename-based check ever becomes content-aware, the capture fails
    /// loudly instead of quietly losing the hero from the marketing shot.
    ///
    /// No-ops when the item already has a save: a real one must always win.
    func seedContinueSaveForCapture() throws {
        guard let item = try recentlyPlayed(limit: 1).first else { return }
        guard saveSlots(forKey: item.savesKey).isEmpty else { return }
        let dir = Self.savesDirectory(forLoadoutID: item.savesKey)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(EngineSaveSlot.autoSaveFilename))
    }
    #endif

    nonisolated static func savesDirectory(forLoadoutID id: UUID) -> URL {
        URL.documentsDirectory
            .appendingPathComponent("Saves", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
