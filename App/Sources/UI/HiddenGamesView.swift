import SwiftUI

/// Games the player took off the shelf, each with Restore (spec §3.3). Hiding
/// is a flag: the row, its files and its saves are all still here.
struct HiddenGamesView: View {
    let library: LibraryService
    @State private var hidden: [Game] = []
    /// The Get Freedoom tile, when the player hid it and it would be on the
    /// shelf again once restored (#552).
    @State private var listsGetFreedoom = false

    var body: some View {
        List {
            if hidden.isEmpty && !listsGetFreedoom {
                EmptyStateView(systemImage: "eye.slash",
                               title: "Nothing is hidden.",
                               hint: "Long-press a tile on the shelf to hide it.")
            }
            if listsGetFreedoom {
                // Laid out as a game's row is, below; it is the offer of a
                // game rather than one, so its name says what it is.
                AccessibilityStack(spacing: Theme.Spacing.sm) {
                    WholeWordText("Get Freedoom")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("hiddenRow-getFreedoom")
                    Button("Restore") {
                        library.restoreGetFreedoom()
                        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                        refresh()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Restore Get Freedoom")
                    .accessibilityIdentifier("restore-getFreedoom")
                }
            }
            ForEach(hidden, id: \.id) { game in
                // No identifier on this stack itself: a container identifier
                // here collapses onto the row and overwrites the Restore
                // button's own identifier below, so the button can no longer
                // be found by it.
                //
                // Side by side at the ordinary text sizes, the name over the
                // button at the accessibility sizes: sharing one line there
                // left each less than its longest word needs, and both were
                // broken ("Free-" / "doom" beside "Restor" / "e", issue #436).
                AccessibilityStack(spacing: Theme.Spacing.sm) {
                    WholeWordText(game.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("hiddenRow-\(game.id)")
                    Button("Restore") {
                        try? library.restore(game)
                        // The shelf sits under Settings as a sheet, so its
                        // `.onAppear` never re-fires on dismissal; without
                        // this post the restored tile would not reappear.
                        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                        refresh()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("restore-\(game.id)")
                }
            }
        }
        .waddleScrollSurface()
        .accessibilityIdentifier("hiddenGamesScreen")
        .navigationTitle("Hidden Games")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        hidden = (try? library.hiddenGames()) ?? []
        listsGetFreedoom = (try? library.hiddenGamesListsGetFreedoom()) ?? false
    }
}
