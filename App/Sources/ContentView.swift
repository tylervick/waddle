import SwiftUI

struct ContentView: View {
    @State private var lastExitCode: Int32?

    var body: some View {
        VStack(spacing: 24) {
            Text("BoomBox")
                .font(.largeTitle.bold())
            Button("Play Freedoom Phase 1") {
                // Clear the previous session's exit label before booting: the
                // smoke test distinguishes "this session exited" from "stale
                // label from the last session" by watching it disappear.
                lastExitCode = nil
                let iwad = Bundle.main.resourceURL!
                    .appendingPathComponent("GameData/freedoom1.wad")
                let saves = URL.documentsDirectory.appendingPathComponent("Saves/freedoom1")
                try? FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
                lastExitCode = EngineSession.play(
                    arguments: ["woof", "-iwad", iwad.path, "-save", saves.path])
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("playFreedoom1")
            if let code = lastExitCode {
                Text("Engine exited: \(code)")
                    .accessibilityIdentifier("engineExitLabel")
            }
        }
    }
}
