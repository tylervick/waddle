import SwiftUI

struct ContentView: View {
    let library: LibraryService
    let importer: ImportService
    @State private var lastExitCode: Int32?

    var body: some View {
        TabView {
            Tab("Play", systemImage: "play.circle.fill") {
                LoadoutGridView(library: library, lastExitCode: $lastExitCode)
            }
            .accessibilityIdentifier("playTab")

            Tab("Library", systemImage: "books.vertical") {
                LibraryView(library: library, importer: importer)
            }
            .accessibilityIdentifier("libraryTab")
        }
        .overlay(alignment: .bottom) {
            if let code = lastExitCode {
                Text("Engine exited: \(code)")
                    .font(.footnote.monospaced())
                    .padding(6)
                    .background(.thinMaterial, in: Capsule())
                    .accessibilityIdentifier("engineExitLabel")
                    .padding(.bottom, 60)
            }
        }
    }
}
