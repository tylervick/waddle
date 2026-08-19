import SwiftUI

struct AboutView: View {
    let library: LibraryService?
    private let sourceURL = URL(string: "https://github.com/tylervick/waddle")!

    /// URL is not Identifiable; the sheet needs an item that is.
    private struct ExportedZip: Identifiable {
        let url: URL
        var id: URL { url }
    }
    @State private var exportedZip: ExportedZip?
    @State private var exportError: String?

    var body: some View {
        List {
            Section {
                LabeledContent("Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                LabeledContent("Build", value: "\(BuildInfo.commit) (\(BuildInfo.branch))")
                LabeledContent("Engine", value: "Woof! (GPL-2.0)")
            }
            Section("Open source") {
                Link("Source code on GitHub", destination: sourceURL)
                Text("Waddle is free software under the GNU GPL v2. It bundles Freedoom and plays your own WAD files; no game data is included from commercial releases.")
                    .font(.footnote)
            }
            Section("Diagnostics") {
                Button("Export Diagnostics") { exportDiagnostics() }
                    .accessibilityIdentifier("exportDiagnosticsButton")
                Text("Bundles recent engine session logs (which can include the names of your WAD files), a log of app events like launches and sessions, crash reports, and device details. Nothing leaves your device unless you share this file.")
                    .font(.footnote)
            }
            Section("Licenses") {
                ForEach(licenseFiles, id: \.0) { name, file in
                    NavigationLink(name) {
                        LicenseTextView(title: name, filename: file)
                    }
                }
            }
        }
        .waddleScrollSurface()
        .navigationTitle("About")
        .accessibilityIdentifier("aboutView")
        .sheet(item: $exportedZip) { zip in
            ShareSheet(items: [zip.url])
        }
        .alert("Export failed", isPresented: .init(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private var licenseFiles: [(String, String)] {
        [("Waddle & Woof! — GPL-3.0", "APP-LICENSE-GPL3"),
         ("Third-party notices", "NOTICES"),
         ("Freedoom — BSD", "FREEDOOM-BSD"),
         ("SDL 3 — zlib", "SDL3-ZLIB"),
         ("OpenAL Soft — LGPL-2.0", "OPENALSOFT-LGPL"),
         ("SONiVOX EAS — Apache-2.0", "SONIVOX-APACHE2"),
         ("SONiVOX EAS — notice", "SONIVOX-NOTICE"),
         ("libsndfile — LGPL-2.1", "LIBSNDFILE-LGPL"),
         ("libogg — BSD", "LIBOGG-BSD"),
         ("libvorbis — BSD", "LIBVORBIS-BSD"),
         ("libFLAC — BSD", "LIBFLAC-BSD"),
         ("libopus — BSD", "LIBOPUS-BSD"),
         ("ZIPFoundation — MIT", "ZIPFOUNDATION-MIT")]
    }

    private func exportDiagnostics() {
        // Library lines are read on the main actor (SwiftData); the file
        // copying/zipping then runs off it so an export can't hitch the UI.
        let lines = DiagnosticsExporter.libraryLines(from: library)
        Task.detached(priority: .userInitiated) {
            // Age-gated sweep, not "delete the immediately-previous export":
            // AirDrop/Save-to-Files can signal sheet dismissal before the
            // receiving side finishes reading the source file, so deleting
            // "the previous" export on every new one could race an in-flight
            // share. An hour-old directory cannot still be streaming.
            DiagnosticsExporter.reclaimStaleExports()
            do {
                let url = try DiagnosticsExporter.export(
                    diagnosticsDirectory: DiagnosticsPaths.directory,
                    libraryLines: lines)
                await MainActor.run { exportedZip = ExportedZip(url: url) }
            } catch {
                await MainActor.run { exportError = error.localizedDescription }
            }
        }
    }
}

struct LicenseTextView: View {
    let title: String
    let filename: String

    var body: some View {
        ScrollView {
            Text(loadText())
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .background(Color.appBackground)
        .navigationTitle(title)
    }

    private func loadText() -> String {
        for ext in ["txt", "md"] {
            if let url = Bundle.main.url(forResource: filename, withExtension: ext,
                                         subdirectory: "Licenses"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return "License text missing from bundle — see the GitHub repository."
    }
}

/// UIActivityViewController wrapper: ShareLink wants its item up front, but
/// the zip is assembled on tap, so the sheet is presented item-driven.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
