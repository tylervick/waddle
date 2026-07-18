import SwiftData
import SwiftUI

@main
struct BoomBoxApp: App {
    let container: ModelContainer
    let library: LibraryService
    let importer: ImportService

    init() {
        do {
            container = try ModelContainer(for: WADFile.self, Loadout.self)
            let context = ModelContext(container)
            let store = WADStore.default
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
                .task { _ = await importer.adoptLooseFiles() }
                .onOpenURL { url in _ = importer.importFiles(at: [url]) }
        }
        .modelContainer(container)
    }
}
