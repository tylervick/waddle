import SwiftUI
import WoofEngine

struct ContentView: View {
    @State private var lastExitCode: Int32?

    var body: some View {
        VStack(spacing: 24) {
            Text("BoomBox")
                .font(.largeTitle.bold())
            Button("Run SDL Spike") {
                lastExitCode = spike_run(5)
            }
            .buttonStyle(.borderedProminent)
            if let code = lastExitCode {
                Text("Spike exit code: \(code)")
                    .accessibilityIdentifier("spikeResult")
            }
        }
    }
}
