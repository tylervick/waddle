import MetricKit
import SwiftData
import SwiftUI

@main
struct WaddleApp: App {
    /// Nil in exactly one process: Xcode's preview host — see `init`.
    let container: ModelContainer?
    let library: LibraryService?
    let importer: ImportService?
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAdopting = false
    @State private var adoptionQueued = false

    init() {
        // The canvas boots this app only as a host for #Preview content; its
        // own scene is never what renders there. Creating the real
        // ModelContainer on that boot path crashes the host outright on
        // current tooling — 2026-08-21 produced six crash reports in one
        // evening, every one a SwiftData assertion under `App.main()` via
        // XOJITExecutor (Xcode 26.2, iOS 26.3.1 simruntime), and a crashing
        // host loops instead of rendering anything. So under previews the app
        // opens no store, subscribes nothing, and records no breadcrumbs;
        // previews build their own in-memory fixtures (`ShelfPreviews.swift`)
        // inside the preview bodies, which is the path that has never crashed.
        // The env var is set by Xcode for every preview host process and by
        // nothing else; the gate compiles away outside DEBUG regardless.
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            container = nil
            library = nil
            importer = nil
            return
        }
        #endif
        do {
            let container = try ModelContainer(for: WADFile.self, Game.self)
            let context = ModelContext(container)
            let store = WADStore.default

            // Test-only seam (same WADDLE_* family as WADDLE_AUTOQUIT_SECONDS
            // and WADDLE_TOUCH_SCHEME): wipes persisted state so UITests that
            // create data (games, saves) start from a clean slate instead
            // of accumulating across runs/devices. Never set in production.
            // Must run before seedBundledContentIfNeeded() below so the
            // bundled base games get re-registered against the fresh store.
            #if DEBUG
            if ProcessInfo.processInfo.environment["WADDLE_RESET_STORE"] != nil {
                try? context.delete(model: WADFile.self)
                try? context.delete(model: Game.self)
                try? context.save()
                try? FileManager.default.removeItem(at: URL.documentsDirectory.appendingPathComponent("WADs", isDirectory: true))
                try? FileManager.default.removeItem(at: URL.documentsDirectory.appendingPathComponent("Saves", isDirectory: true))
                // Clear both migration flags too, so the reset seam yields a
                // genuinely pre-migration slate rather than one that skips
                // the seeder's game-creation because a flag survived the wipe.
                UserDefaults.standard.removeObject(forKey: LibraryService.didMigrateToGamesKey)
                UserDefaults.standard.removeObject(forKey: LibraryService.didAdoptOrphanMapSetsKey)
                // And the layout editor's button positions (issue #115), so
                // a UITest that drags a button cannot leave it moved for the
                // rest of the suite.
                UserDefaults.standard.removeObject(forKey: TouchOverlayLayoutOverrides.userDefaultsKey)
            }
            #endif

            let library = LibraryService(context: context, store: store)
            let importer = ImportService(library: library, store: store)
            // The migration and the seeder are interchangeable for bundled
            // rows — see each method's doc comment: both build the same
            // `Game.baseGame(for:)` under the same guard. The order that is
            // load-bearing is seed before adopt.
            try library.migrateToGames()
            // Test-only seam (issue #504), same WADDLE_* family as the reset
            // above: WADDLE_TEST_FREEDOOM_DIR is a directory holding
            // freedoom1.wad and freedoom2.wad (the UI-test runner's own
            // copies), installed as imported files with their base games *in
            // place of* the bundled seeder, so a UI test plays Freedoom without
            // the app bundle carrying it. After the reset, so its wipe of
            // Documents/WADs cannot undo it; before adoption, like the seeder,
            // so the bases exist to pair with. Never set in production, and
            // compiled out of Release.
            #if DEBUG
            if let testFreedoom = ProcessInfo.processInfo.environment["WADDLE_TEST_FREEDOOM_DIR"] {
                do {
                    try library.installFreedoomForTest(from: URL(fileURLWithPath: testFreedoom))
                } catch {
                    fatalError("WADDLE_TEST_FREEDOOM_DIR=\(testFreedoom): \(error)")
                }
            } else {
                try library.seedBundledContentIfNeeded()
            }
            #else
            try library.seedBundledContentIfNeeded()
            #endif
            // After the seeder, so bundled bases exist to pair with.
            try library.adoptOrphanMapSets()

            // Test-only seam, same WADDLE_* family as the reset above. Gives
            // the most-recently-played item a save so the shelf's Continue
            // hero renders, which App Store capture needs and cannot otherwise
            // get: Woof writes its autosave only from `G_DoWorldDone`
            // (`Engine/woof/src/g_game.c:2002`) — level *completion*, not level
            // start — and `-warp` enters through `G_InitNew`, which does not
            // autosave at all. A capture session warps in, never finishes the
            // level, and so leaves `Documents/Saves/<id>/` empty; the shot then
            // has no hero, which is exactly what the 2026-08-15 capture
            // produced. Never set in production.
            #if DEBUG
            if ProcessInfo.processInfo.environment["WADDLE_SEED_CONTINUE_SAVE"] != nil {
                try? library.seedContinueSaveForCapture()
            }
            // Test-only seam (issue #429): WADDLE_TEST_SEED_SAVE_FOR names a
            // game to give one save, so a UI test can reach the game page's
            // change-with-saves warning on a game that has a base to change.
            // Same WADDLE_* family as the seams around it; never set in
            // production.
            if let name = ProcessInfo.processInfo.environment["WADDLE_TEST_SEED_SAVE_FOR"] {
                try? library.seedSaveForTest(gameNamed: name)
            }
            // Test-only seam (issue #339): WADDLE_TEST_SUSPEND_SAVE is a save
            // file, raw-deflate compressed and base64 encoded (a 1.3 save is
            // 171 KB; the launch environment is not the place for that), to
            // install as Freedoom Phase 1's suspend save before the shelf is
            // built. Same WADDLE_* family as the seams above; never set in
            // production.
            if let encoded = ProcessInfo.processInfo.environment["WADDLE_TEST_SUSPEND_SAVE"],
               let compressed = Data(base64Encoded: encoded),
               let bytes = try? (compressed as NSData).decompressed(using: .zlib) as Data {
                try? library.seedSuspendSaveForTest(bytes)
            }
            // Test-only seam (issue #513): WADDLE_TEST_LOOSE_FILE is a file's
            // bytes, base64 encoded, written into Documents under the name
            // WADDLE_TEST_LOOSE_FILE_NAME before the launch's adoption pass,
            // exactly where a Files-app drop (or Scripts/provision-test-wads.sh)
            // puts one. It lets a UI test bring its own small synthetic WAD
            // rather than depend on a fixture provisioned by hand. Same
            // WADDLE_* family as the seams above; never set in production.
            if let encoded = ProcessInfo.processInfo.environment["WADDLE_TEST_LOOSE_FILE"],
               let name = ProcessInfo.processInfo.environment["WADDLE_TEST_LOOSE_FILE_NAME"],
               let bytes = Data(base64Encoded: encoded) {
                let leaf = URL(fileURLWithPath: name).lastPathComponent
                try? bytes.write(to: URL.documentsDirectory.appendingPathComponent(leaf))
            }
            #endif

            self.container = container
            self.library = library
            self.importer = importer
        } catch {
            fatalError("SwiftData container failed: \(error)")
        }
        MXMetricManager.shared.add(DiagnosticsMetricSubscriber.shared)
        // Last line of init on purpose: it is the first breadcrumb of this
        // launch, and a trail that begins after a failed setup would be
        // describing a process that never got this far.
        BreadcrumbLog.shared.record(.appLaunch)
        UsageStore.shared.recordLaunch(version: UsageStore.currentAppVersion())
    }

    var body: some Scene {
        WindowGroup {
            // `SceneBuilder` cannot branch, so the preview-host split lives
            // here and `.modelContainer` rides the root view instead of the
            // scene — same environment, one window either way.
            if let container, let library, let importer {
                Group {
                    #if DEBUG
                    if let proto = ProtoScene.current {
                        ProtoRoot(scene: proto, library: library)
                    } else {
                        ContentView(library: library, importer: importer)
                    }
                    #else
                    ContentView(library: library, importer: importer)
                    #endif
                }
                    .task { await runAdoption() }
                    .onChange(of: scenePhase) { oldPhase, newPhase in
                        BreadcrumbLog.shared.record(
                            .scenePhase(from: Self.phaseName(oldPhase),
                                        to: Self.phaseName(newPhase)))
                        // Launch is covered by .task above; this catches files dropped
                        // into Documents via the Files app while we were backgrounded.
                        guard oldPhase == .background, newPhase == .active else { return }
                        Task { await runAdoption() }
                    }
                    .onOpenURL { url in
                        Task { await importer.importFile(at: url, from: .openIn) }
                    }
                    .modelContainer(container)
            } else {
                // The preview host's scene, which the canvas never shows —
                // it renders the #Preview content in its place.
                Color.black.ignoresSafeArea()
            }
        }
    }

    /// ScenePhase has no textual form worth leaning on, so the three cases
    /// are spelled out here: the breadcrumb wording is what a human reads six
    /// weeks later, and it must not shift under an SDK update.
    private static func phaseName(_ phase: ScenePhase) -> String {
        switch phase {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }

    /// One adoption pass: sweep loose files from Documents/Inbox into the
    /// store, surface the outcome, and nudge the shelf and Files to refresh
    /// (adoption can finish after they first rendered). Guarded so a launch
    /// pass and a foreground pass can't interleave store writes.
    // An overlapping trigger queues a trailing pass instead of being
    // dropped: a file dropped into Documents after the in-flight pass
    // listed the directory is caught by the re-run, so every trigger is
    // still followed by a scan + refresh.
    @MainActor
    private func runAdoption() async {
        guard let importer else { return }
        guard !isAdopting else { adoptionQueued = true; return }
        isAdopting = true
        defer { isAdopting = false }
        repeat {
            adoptionQueued = false
            await importer.adoptLooseFiles()
        } while adoptionQueued
    }
}
