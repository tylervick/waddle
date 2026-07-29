import SwiftData
import SwiftUI

@main
struct WADdleApp: App {
    let container: ModelContainer
    let library: LibraryService
    let importer: ImportService
    @Environment(\.scenePhase) private var scenePhase
    @State private var isAdopting = false
    @State private var adoptionQueued = false

    init() {
        do {
            container = try ModelContainer(for: WADFile.self, Loadout.self)
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

            library = LibraryService(context: context, store: store)
            importer = ImportService(library: library, store: store)
            try library.seedBundledContentIfNeeded()
            try library.reconcileBundledBaseGameLoadouts()
        } catch {
            fatalError("SwiftData container failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library, importer: importer)
                .task { await runAdoption() }
                .onChange(of: scenePhase) { oldPhase, newPhase in
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
        }
        .modelContainer(container)
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
