import SwiftUI

/// Games the player took off the shelf, each with Restore (spec §3.3). Hiding
/// is a flag: the row, its files and its saves are all still here.
struct HiddenGamesView: View {
    let library: LibraryService
    @State private var hidden: [Game] = []

    var body: some View {
        List {
            if hidden.isEmpty {
                Text("Nothing is hidden. Long-press a tile on the shelf to hide it.")
                    .foregroundStyle(.secondary)
            }
            ForEach(hidden, id: \.id) { game in
                HStack {
                    Text(game.name)
                    Spacer()
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
                .accessibilityIdentifier("hiddenRow-\(game.id)")
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
    }
}
