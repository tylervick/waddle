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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(baseGames) { base in
                Button(base.displayName) { path = base }
                    .accessibilityIdentifier("createPresetBase-\(base.displayName)")
            }
            .waddleScrollSurface()
            .navigationTitle("New Preset")
            .navigationDestination(item: $path) { base in
                // `onComplete: { dismiss() }` closes the whole sheet (this
                // view's own dismiss, since this is the sheet's root) rather
                // than letting the editor's `dismiss()` merely pop back to
                // this picker -- see `LoadoutEditorView.onComplete`.
                LoadoutEditorView(library: library, existing: nil, seedIWAD: base,
                                   onComplete: { dismiss() })
            }
            .onAppear {
                baseGames = (try? library.baseGames()) ?? []
            }
        }
    }
}
