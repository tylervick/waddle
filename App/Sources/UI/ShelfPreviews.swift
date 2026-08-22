#if DEBUG
import SwiftData
import SwiftUI

/// Xcode-canvas fixtures for the shelf: an in-memory library built the same
/// way `LibraryServiceTests` builds one, seeded with the bundled Freedoom
/// IWADs so tiles decode real TITLEPIC art in the canvas. Nothing here ships
/// — the whole file is compiled out of Release, which is also what lets it
/// call the DEBUG-only `seedContinueSaveForCapture()`.
///
/// The store's directory is a throwaway under the preview host's temp dir; it
/// only ever matters for *imported* files, and these fixtures import nothing.
/// Bundled WADs resolve straight into the app bundle's GameData/, which the
/// preview host loads like any other run of the target.
@MainActor
private enum ShelfPreviewFixture {
    /// A factory-state library: bundled base games registered, nothing played,
    /// no saves — the shelf a first launch shows, welcome card and all.
    static func factory() -> (library: LibraryService, importer: ImportService) {
        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: WADFile.self, Loadout.self,
                                               configurations: config)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let store = WADStore(directory: tmp)
            let library = LibraryService(context: ModelContext(container), store: store)
            try library.seedBundledContentIfNeeded()
            return (library, ImportService(library: library, store: store))
        } catch {
            fatalError("Shelf preview fixture failed: \(error)")
        }
    }

    /// The factory library with Freedoom Phase 1 marked played and holding a
    /// seeded autosave, so `Shelf.heroZone` resolves to the Continue hero.
    /// The save lands in the preview sandbox's Documents/Saves/<fresh UUID>/,
    /// same as the capture flow's — an empty marker file, never read.
    static func continueHero() -> (library: LibraryService, importer: ImportService) {
        let fixture = factory()
        do {
            if let wad = try fixture.library.baseGames().first {
                try fixture.library.markPlayed(wad)
                try fixture.library.seedContinueSaveForCapture()
            }
        } catch {
            fatalError("Shelf preview fixture failed: \(error)")
        }
        return fixture
    }
}

/// The `NavigationStack` + dark pin mirror `ContentView`, which is where the
/// real shelf gets both; without the stack the toolbar has nowhere to land.
private struct ShelfPreviewHost: View {
    let fixture: (library: LibraryService, importer: ImportService)

    var body: some View {
        NavigationStack {
            ShelfView(library: fixture.library,
                      importer: fixture.importer,
                      lastExitCode: .constant(nil))
        }
        .preferredColorScheme(.dark)
    }
}

/// First launch: welcome card over the bundled Freedoom tiles.
#Preview("Factory state") {
    ShelfPreviewHost(fixture: ShelfPreviewFixture.factory())
}

/// A returning player: Continue hero over the grid.
#Preview("Continue hero") {
    ShelfPreviewHost(fixture: ShelfPreviewFixture.continueHero())
}

/// The geometry every recent sizing defect lived in: a short viewport where
/// the hero cap and the fold clearance actually bind.
#Preview("Continue hero, landscape", traits: .landscapeLeft) {
    ShelfPreviewHost(fixture: ShelfPreviewFixture.continueHero())
}
#endif
