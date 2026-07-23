import SwiftUI

/// Auto-naming for presets created via `PresetCreationFlow`: "<base game>"
/// alone, or "<base game> + <PWAD> + <PWAD> ..." once mods are added.
/// `LoadoutEditorView` re-derives this on every PWAD list change until the
/// user edits the name field by hand.
enum PresetName {
    static func suggested(base: String, pwads: [String]) -> String {
        pwads.isEmpty ? base : base + " + " + pwads.joined(separator: " + ")
    }
}

/// The single door into preset creation (Plan B Task 4): pick a base game,
/// then push straight into `LoadoutEditorView` pre-seeded with it. Replaces
/// the old blank "New Loadout" sheet and the Library PWAD-swipe/context-menu
/// shortcut -- there is exactly one way to create a preset now.
struct PresetCreationFlow: View {
    let library: LibraryService

    @State private var baseGames: [WADFile] = []
    @State private var path: WADFile?

    var body: some View {
        NavigationStack {
            List(baseGames) { base in
                Button(base.displayName) { path = base }
                    .accessibilityIdentifier("createPresetBase-\(base.displayName)")
            }
            .navigationTitle("New Preset")
            .navigationDestination(item: $path) { base in
                LoadoutEditorView(library: library, existing: nil, seedIWAD: base)
            }
            .onAppear {
                baseGames = (try? library.baseGames()) ?? []
            }
        }
    }
}
