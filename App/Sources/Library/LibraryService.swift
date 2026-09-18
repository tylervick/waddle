import Foundation
import SwiftData

enum LibraryError: Error, Equatable {
    /// The file is loaded by these games (spec §4.4) — remove it from them first.
    case wadInUse([String])
    /// Base games are hidden, never deleted (spec §4.4).
    case cannotDeleteBaseGame
    /// Bundled files are never deletable (spec §4.4): they live in the signed
    /// app bundle, and deleting the row would orphan its base game's saves —
    /// the seeder would simply re-create both under a fresh id.
    case wadIsBundled
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
    /// GameData/) and their base games. Safe to call every launch: each row
    /// stores its real content SHA-1 (so imports of byte-identical files dedupe
    /// against it), but the hash is computed only the one time the row is
    /// created — steady-state launches skip straight past the existence checks
    /// and never re-hash the ~30MB bundle files.
    ///
    /// The base game is created only when no `Game` with the IWAD's id exists,
    /// hidden or not (spec §4.5). A hidden game still exists, so the player's
    /// "Remove from Shelf" survives every launch and no second game with a
    /// fresh id — and an empty saves directory — is ever made for it. Pinned by
    /// `GameServiceTests.testSeederLeavesAHiddenBaseGameAlone`.
    ///
    /// Must run **after** `migrateToGames()`: on an upgraded install the
    /// migration is what creates the bundled rows' base games, carrying their
    /// hidden flag and last-played date across. Run first, this would create
    /// them blank.
    func seedBundledContentIfNeeded() throws {
        let bundled: [(file: String, title: String, family: GameFamily)] = [
            ("freedoom1.wad", "Freedoom Phase 1", .doom1),
            ("freedoom2.wad", "Freedoom Phase 2", .doom2),
        ]
        for entry in bundled {
            let wad: WADFile
            if let existing = try wadByFilename(entry.file, bundled: true) {
                wad = existing
                wad.hasMaps = true   // IWADs carry maps; upgraded installs must match fresh ones.
            } else {
                wad = WADFile(filename: entry.file, displayName: entry.title,
                              kindRaw: WADKind.iwad.rawValue,
                              sha1: try WADStore.sha1(ofFileAt: Self.bundledURL(forFilename: entry.file)),
                              gameFamilyRaw: entry.family.rawValue, isBundled: true, hasMaps: true)
                context.insert(wad)
            }
            if try game(id: wad.id) == nil {
                context.insert(Game.baseGame(for: wad))
            }
        }
        try context.save()
    }

    /// `UserDefaults` keys for the two one-time launch-order migration steps
    /// (see `WaddleApp`, which also clears both under `WADDLE_RESET_STORE`).
    static let didReconcileBundledBaseGameLoadoutsKey = "didReconcileBundledBaseGameLoadouts"
    static let didMigrateToGamesKey = "didMigrateToGames"

    /// Titles the one-door preset flow auto-assigns a modless Freedoom preset,
    /// which is indistinguishable from the legacy phantom shape (no PWAD/DEH,
    /// bundled IWAD) `reconcileBundledBaseGameLoadouts` removes.
    private static let seededTitles: Set<String> = ["Freedoom Phase 1", "Freedoom Phase 2"]

    /// Shape-only test for the legacy phantom: a modless loadout named exactly
    /// one of `seededTitles` on a *bundled* IWAD. Shared by
    /// `reconcileBundledBaseGameLoadouts` (which deletes a lone match) and
    /// `migrateToGames` (which must not turn one into a permanent `Game`
    /// before the reconcile has had a chance to remove it — see that method's
    /// doc comment).
    private func isPhantomBundledLoadout(_ loadout: Loadout) throws -> Bool {
        guard loadout.pwadIDs.isEmpty && loadout.dehIDs.isEmpty
                && Self.seededTitles.contains(loadout.name) else { return false }
        return try wad(id: loadout.iwadID)?.isBundled == true
    }

    /// One-time migration: earlier builds auto-created a Loadout per bundled
    /// Freedoom phase so the base game could launch. Base games are now
    /// directly playable, so these phantom loadouts are removed once; any saves
    /// they accumulated migrate to the base game's own saves key (its
    /// WADFile.id), so on-device progress survives. User-authored presets are
    /// never touched.
    ///
    /// Guarded by a persisted flag so this runs at most once per install.
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
        let flagKey = Self.didReconcileBundledBaseGameLoadoutsKey
        guard !defaults.bool(forKey: flagKey) else { return }

        // Candidates: modless loadouts with a seeded title on a *bundled* IWAD.
        var phantoms: [Loadout] = []
        for loadout in try context.fetch(FetchDescriptor<Loadout>())
        where try isPhantomBundledLoadout(loadout) {
            phantoms.append(loadout)
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

    /// One-time migration onto `Game` (spec §5). Every IWAD row becomes its
    /// base game and every `Loadout` becomes a game, **each under its old id**,
    /// so `Documents/Saves/<id>/` stays exactly where the previous build left
    /// it and a player updating mid-campaign gets their Continue hero back.
    /// Present PWADs are re-parsed to fill `hasMaps`; a missing or unreadable
    /// file keeps the default.
    ///
    /// Runs at most once per install (persisted flag), and never overwrites a
    /// game that already exists — the legacy fields are copied only into games
    /// this call creates. The `Loadout` rows and `WADFile`'s moved fields are
    /// left in place: written by nothing from here on, dropped by a later
    /// release. Same pattern as `reconcileBundledBaseGameLoadouts`, and it
    /// must run after it (so phantom loadouts are gone) and **before**
    /// `seedBundledContentIfNeeded()` (so the bundled rows' games are made here,
    /// with their flags, rather than blank by the seeder).
    ///
    /// Not gated on the reconcile flag as a whole — that would silently skip
    /// every user preset forever on an install where the reconcile never
    /// manages to set it (e.g. a save migration keeps failing). Instead, only
    /// a loadout that still matches the phantom shape is skipped while the
    /// reconcile flag is unset, so it is picked up as a game on whatever later
    /// launch finally reconciles or permanently fails to (in which case it
    /// migrates as an ordinary, if oddly named, game rather than vanishing).
    func migrateToGames(defaults: UserDefaults = .standard) throws {
        let flagKey = Self.didMigrateToGamesKey
        guard !defaults.bool(forKey: flagKey) else { return }

        for wad in try allWADs() where wad.kindRaw == WADKind.iwad.rawValue {
            guard try game(id: wad.id) == nil else { continue }
            let game = Game.baseGame(for: wad)
            game.schemeOverrideRaw = wad.schemeOverrideRaw
            game.isHidden = wad.isHidden
            game.lastPlayed = wad.lastPlayed
            context.insert(game)
        }
        let reconcileHasRun = defaults.bool(forKey: Self.didReconcileBundledBaseGameLoadoutsKey)
        for loadout in try context.fetch(FetchDescriptor<Loadout>()) {
            guard try game(id: loadout.id) == nil else { continue }
            if try !reconcileHasRun && isPhantomBundledLoadout(loadout) { continue }
            context.insert(Game(id: loadout.id, name: loadout.name, baseID: loadout.iwadID,
                                fileIDs: loadout.pwadIDs + loadout.dehIDs,
                                complevel: loadout.complevel,
                                schemeOverrideRaw: loadout.schemeOverrideRaw,
                                isHidden: loadout.isHidden, lastPlayed: loadout.lastPlayed,
                                createdAt: loadout.createdAt, isBaseGame: false))
        }
        for wad in try allWADs() where wad.kindRaw == WADKind.pwad.rawValue {
            // Directory only: `WADParser.parse` reads the header and lump table,
            // and the mapping keeps a 300 MB megawad from becoming one allocation.
            guard let data = try? Data(contentsOf: fileURL(for: wad), options: .mappedIfSafe),
                  let parsed = try? WADParser.parse(data) else { continue }
            wad.hasMaps = WADParser.mapFormat(of: parsed.lumpNames) != .none
        }
        try context.save()
        defaults.set(true, forKey: flagKey)
    }

    /// Moves the legacy per-loadout saves dir onto the base game's saves key.
    /// If the destination already exists, merges file-by-file and never
    /// overwrites an existing base-game save (its version wins; the stale
    /// duplicate is left in place, not deleted). Throws on any filesystem
    /// failure so the caller can keep the loadout instead of orphaning saves.
    private func migrateSaves(fromKey old: UUID, toKey new: UUID) throws {
        let fm = FileManager.default
        let src = Self.savesDirectory(forGameID: old)
        let dst = Self.savesDirectory(forGameID: new)
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

    /// Every installed IWAD — bundled first, then by title. This is the base
    /// picker's list (spec §3.2); whether the IWAD's own game is hidden is a
    /// shelf matter and does not remove it from here.
    func baseGames() throws -> [WADFile] {
        try allWADs()
            .filter { $0.kindRaw == WADKind.iwad.rawValue }
            .sorted { ($0.isBundled ? 0 : 1, $0.displayName) < ($1.isBundled ? 0 : 1, $1.displayName) }
    }

    // MARK: Games

    /// Every game, most recently played first, then newest created. Backs the
    /// Manage inventory and the diagnostics dump — the shelf reads
    /// `shelfGames()`.
    func games() throws -> [Game] {
        try context.fetch(FetchDescriptor<Game>()).sorted {
            ($0.lastPlayed ?? $0.createdAt) > ($1.lastPlayed ?? $1.createdAt)
        }
    }

    /// Everything the shelf shows, unordered by shelf rules (`Shelf.ordered`
    /// does that): every game minus hidden ones. "A hidden game never reaches
    /// the shelf" is a property of this one call.
    func shelfGames() throws -> [Game] {
        try games().filter { !$0.isHidden }
    }

    /// Everything the player took off the shelf, for the Restore list.
    func hiddenGames() throws -> [Game] {
        try games().filter(\.isHidden)
    }

    func game(id: UUID) throws -> Game? {
        var descriptor = FetchDescriptor<Game>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Games that load `fileID` as their base or in their file list. An IWAD's
    /// own base game is included — `deleteWAD` is the one caller that has to
    /// set it aside.
    func gamesUsing(fileID: UUID) throws -> [Game] {
        try context.fetch(FetchDescriptor<Game>()).filter {
            $0.baseID == fileID || $0.fileIDs.contains(fileID)
        }
    }

    /// Games that have been played, most-recent-first, capped.
    func recentlyPlayed(limit: Int) throws -> [Game] {
        try games()
            .filter { $0.lastPlayed != nil }
            .sorted { ($0.lastPlayed ?? .distantPast) > ($1.lastPlayed ?? .distantPast) }
            .prefix(limit)
            .map { $0 }
    }

    /// True while the library is still exactly what the app shipped with:
    /// nothing imported, no game but the bundled base games, and nothing saved
    /// anywhere (launcher spec §4). Once any of the three stops holding, it
    /// never holds again, so the welcome card does not come back.
    ///
    /// It asks the *whole* library, not `shelfGames()`: a mod arriving by
    /// share sheet is not (yet) a game and a hidden game is not on the shelf,
    /// but both mean somebody's own things are in here. "Any save" means any
    /// file in any game's saves directory, not a *resumable* one — that
    /// stricter question is the Continue hero's
    /// (`GameLauncher.continuableSlot`).
    func isFactoryState() throws -> Bool {
        let wads = try allWADs()
        guard !wads.contains(where: { !$0.isBundled }) else { return false }
        let games = try games()
        guard !games.contains(where: { !$0.isBaseGame }) else { return false }
        return !games.contains { !saveSlots(forKey: $0.id).isEmpty }
    }

    func allWADs() throws -> [WADFile] {
        try context.fetch(FetchDescriptor<WADFile>(
            sortBy: [SortDescriptor(\.importDate, order: .reverse)]))
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

    @discardableResult
    func registerImported(filename: String, sha1: String, kind: String,
                          family: String, hasMaps: Bool = false) throws -> WADFile {
        // Content-derived title first, filename only as a fallback: a
        // recognized commercial IWAD is titled by what it *is*, so renaming
        // doom2.wad before importing it cannot change what the shelf calls it.
        // Anything unrecognized — every PWAD, every mod — keeps the filename
        // behaviour this line has always had.
        let wad = WADFile(filename: filename,
                          displayName: recognizedTitle(sha1)
                              ?? (filename as NSString).deletingPathExtension,
                          kindRaw: kind, sha1: sha1, gameFamilyRaw: family, hasMaps: hasMaps)
        context.insert(wad)
        // An IWAD is a game the moment it arrives (spec §2.1). Map sets become
        // games in plan 3; add-ons never do.
        if kind == WADKind.iwad.rawValue {
            context.insert(Game.baseGame(for: wad))
        }
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

    /// Persists in-place mutations made directly to fetched/created model
    /// instances (e.g. editing a Game's fields, or bumping lastPlayed) —
    /// those mutations aren't saved on their own; SwiftData's autosave is not
    /// immediate/guaranteed at the point callers need it.
    func saveChanges() throws {
        try context.save()
    }

    @discardableResult
    func createGame(name: String, baseID: UUID?, fileIDs: [UUID],
                    complevel: String? = nil) throws -> Game {
        let game = Game(name: name, baseID: baseID, fileIDs: fileIDs, complevel: complevel)
        context.insert(game)
        try context.save()
        return game
    }

    /// Deletes a game and its saves (spec §4.3). Base games are hidden, never
    /// deleted (spec §4.4). Whether to also delete the game's files is the
    /// caller's decision (`deleteWAD`), made with the "used by" answer in hand.
    func deleteGame(_ game: Game) throws {
        guard !game.isBaseGame else { throw LibraryError.cannotDeleteBaseGame }
        try? FileManager.default.removeItem(at: Self.savesDirectory(forGameID: game.id))
        context.delete(game)
        try context.save()
    }

    /// Off the shelf without destroying anything: the row, its files and its
    /// saves all stay put. Reversible with `restore(_:)`.
    func hide(_ game: Game) throws {
        game.isHidden = true
        try context.save()
    }

    func restore(_ game: Game) throws {
        game.isHidden = false
        try context.save()
    }

    /// Date is injectable for deterministic tests.
    func markPlayed(_ game: Game, at date: Date = .now) throws {
        game.lastPlayed = date
        try context.save()
    }

    /// Sets (or clears, with `nil`) a game's touch-layout override.
    func setSchemeOverride(_ raw: String?, for game: Game) throws {
        game.schemeOverrideRaw = raw
        try context.save()
    }

    /// Deletes a file (spec §4.4). Bundled files are never deletable — the
    /// row stays, since removing it would orphan its base game's saves (the
    /// seeder would just re-create both under a fresh id). Otherwise blocked
    /// while any game *other than the IWAD's own base game* loads it — that
    /// carve-out is what makes an imported IWAD deletable at all. Deleting an
    /// IWAD takes its base game and that game's saves with it.
    func deleteWAD(_ wad: WADFile) throws {
        guard !wad.isBundled else { throw LibraryError.wadIsBundled }
        let blockers = try gamesUsing(fileID: wad.id)
            .filter { $0.id != wad.id }
        if !blockers.isEmpty {
            throw LibraryError.wadInUse(blockers.map(\.name))
        }
        if let own = try game(id: wad.id), own.isBaseGame {
            try? FileManager.default.removeItem(at: Self.savesDirectory(forGameID: own.id))
            context.delete(own)
        }
        if !wad.isBundled {
            try? store.delete(filename: wad.filename)
        }
        context.delete(wad)
        try context.save()
    }

    // MARK: Saves

    /// A single visible save file in a game's saves directory (see
    /// `savesDirectory(forGameID:)`); `id` is the filename.
    struct SaveSlot: Identifiable, Equatable {
        let id: String
        let modified: Date
    }

    /// Lists the save files for a game's id, newest-modified first. Empty
    /// (not throwing) if the directory is missing or unreadable -- a brand
    /// new item simply has no saves yet.
    func saveSlots(forKey id: UUID) -> [SaveSlot] {
        let dir = Self.savesDirectory(forGameID: id)
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

    /// Deletes one save file for a game's id. Best-effort -- a missing file
    /// is not an error.
    func deleteSave(_ slot: SaveSlot, forKey id: UUID) {
        try? FileManager.default.removeItem(
            at: Self.savesDirectory(forGameID: id).appendingPathComponent(slot.id))
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
    /// Driven by `WADDLE_SEED_CONTINUE_SAVE` (see `WaddleApp`).
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
        guard saveSlots(forKey: item.id).isEmpty else { return }
        let dir = Self.savesDirectory(forGameID: item.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent(EngineSaveSlot.autoSaveFilename))
    }
    #endif

    nonisolated static func savesDirectory(forGameID id: UUID) -> URL {
        URL.documentsDirectory
            .appendingPathComponent("Saves", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
}
