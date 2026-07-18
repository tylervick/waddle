import SwiftUI

struct AboutView: View {
    private let sourceURL = URL(string: "https://github.com/tylervick/boombox")!

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
                Text("BoomBox is free software under the GNU GPL v2. It bundles Freedoom and plays your own WAD files; no game data is included from commercial releases.")
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
        .navigationTitle("About")
        .accessibilityIdentifier("aboutView")
    }

    private var licenseFiles: [(String, String)] {
        [("BoomBox & Woof! — GPL-2.0", "APP-LICENSE-GPL2"),
         ("Third-party notices", "NOTICES"),
         ("Freedoom — BSD", "FREEDOOM-BSD"),
         ("SDL 3 — zlib", "SDL3-ZLIB"),
         ("OpenAL Soft — LGPL-2.0", "OPENALSOFT-LGPL"),
         ("ZIPFoundation — MIT", "ZIPFOUNDATION-MIT")]
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
