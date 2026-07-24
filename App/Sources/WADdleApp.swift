import SwiftData
import SwiftUI

@main
struct WADdleApp: App {
    let container: ModelContainer
    let library: LibraryService
    let importer: ImportService

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
        } catch {
            fatalError("SwiftData container failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(library: library, importer: importer)
                .task {
                    ImportNotices.shared.post(outcome: await importer.adoptLooseFiles(),
                                              quarantines: true)
                }
                .onOpenURL { url in
                    let outcome = importer.importFiles(at: [url])
                    ImportNotices.shared.post(outcome: outcome)
                    NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                }
        }
        .modelContainer(container)
    }
}
