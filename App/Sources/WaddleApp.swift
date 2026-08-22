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
            let container = try ModelContainer(for: WADFile.self, Loadout.self)
            let context = ModelContext(container)
            let store = WADStore.default

            // Test-only seam (same WADDLE_* family as WADDLE_AUTOQUIT_SECONDS
            // and WADDLE_TOUCH_SCHEME): wipes persisted state so UITests that
            // create data (presets, saves) start from a clean slate instead
            // of accumulating across runs/devices. Never set in production.
            // Must run before seedBundledContentIfNeeded() below so the
            // bundled base games get re-registered against the fresh store.
            #if DEBUG
            if ProcessInfo.processInfo.environment["WADDLE_RESET_STORE"] != nil {
                try? context.delete(model: WADFile.self)
                try? context.delete(model: Loadout.self)
                try? context.save()
                try? FileManager.default.removeItem(at: URL.documentsDirectory.appendingPathComponent("WADs", isDirectory: true))
                try? FileManager.default.removeItem(at: URL.documentsDirectory.appendingPathComponent("Saves", isDirectory: true))
            }
            #endif

            let library = LibraryService(context: context, store: store)
            let importer = ImportService(library: library, store: store)
            try library.seedBundledContentIfNeeded()
            try library.reconcileBundledBaseGameLoadouts()

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
    }

    var body: some Scene {
        WindowGroup {
            // `SceneBuilder` cannot branch, so the preview-host split lives
            // here and `.modelContainer` rides the root view instead of the
            // scene — same environment, one window either way.
            if let container, let library, let importer {
                ContentView(library: library, importer: importer)
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
                        let outcome = importer.importFiles(at: [url])
                        ImportNotices.shared.post(outcome: outcome)
                        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
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
    /// store, surface the outcome, and nudge LibraryView to refresh (adoption
    /// can finish after the Library list first rendered). Guarded so a launch
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
            ImportNotices.shared.post(outcome: await importer.adoptLooseFiles(),
                                      quarantines: true)
            NotificationCenter.default.post(name: .libraryDidChange, object: nil)
        } while adoptionQueued
    }
}
