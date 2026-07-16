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
                lastExitCode = EngineSession.play(iwad: "freedoom1.wad")
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
