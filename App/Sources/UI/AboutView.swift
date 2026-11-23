import MessageUI
import SwiftUI

struct AboutView: View {
    let library: LibraryService?
    private let sourceURL = URL(string: "https://github.com/tylervick/waddle")!

    /// URL is not Identifiable; the sheet needs an item that is.
    private struct ExportedZip: Identifiable {
        let url: URL
        var id: URL { url }
    }
    /// Where the share sheet and the failure alert are kept when Settings is
    /// the shelf's panel (`PanelPresentation.swift`); nil keeps them here.
    var presentation: SettingsPresentation?
    @State private var ownPresentation = SettingsPresentation()
    private var shown: SettingsPresentation { presentation ?? ownPresentation }
    @Environment(\.panelHost) private var host
    @Environment(\.openURL) private var openURL

    /// The mail sheet's composition; not Identifiable on its own.
    private struct FeedbackSheet: Identifiable {
        let composition: FeedbackMail.Composition
        var id: String { composition.attachments.map(\.url.path).joined() }
    }

    var body: some View {
        List {
            // The mark, as the subject of the one screen that is about the
            // app rather than the games (design-system spec §5): drawn on
            // the page, not in a grouped cell, and at the larger integer
            // scale so the pixel face stays crisp.
            Section {
                Image("WaddleWordmark")
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(height: Theme.wordmarkHeightLarge)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.md)
                    .accessibilityLabel("Waddle")
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            Section {
                LabeledContent("Version",
                    value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                LabeledContent("Build", value: "\(BuildInfo.commit) (\(BuildInfo.branch))")
                LabeledContent("Engine", value: "Woof! (GPL-2.0)")
            }
            Section {
                Link("Source code on GitHub", destination: sourceURL)
                Text("Waddle is free software under the GNU GPL v3. It bundles Freedoom and plays your own WAD files; no game data is included from commercial releases.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Color.appSecondaryText)
            } header: {
                WaddleSectionHeader("Open source")
            }
            // Both rows hand off to something the user sends themselves, after
            // seeing what it carries; the app makes no connection (issue #484,
            // PRIVACY.md).
            Section {
                Button("Report a bug") { shown.confirmBugReport = true }
                    .accessibilityIdentifier("reportBugButton")
                Text("Attaches the same diagnostics file as Export Diagnostics. You can remove it before sending.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Color.appSecondaryText)
                Button("Send feedback") { sendFeedback() }
                    .accessibilityIdentifier("sendFeedbackButton")
            } header: {
                WaddleSectionHeader("Feedback")
            }
            Section {
                Button("Export Diagnostics") { exportDiagnostics() }
                    .accessibilityIdentifier("exportDiagnosticsButton")
                Text("Bundles recent engine session logs (which can include the names of your WAD files), a log of app events like launches and sessions, crash reports, and device details. Nothing leaves your device unless you share this file.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Color.appSecondaryText)
            } header: {
                WaddleSectionHeader("Diagnostics")
            }
            Section {
                ForEach(licenseFiles, id: \.0) { name, file in
                    // A value, where the stack this is in keeps its path
                    // (Settings); a destination anywhere else.
                    if presentation != nil {
                        NavigationLink(name, value: SettingsPresentation.Route.license(title: name, filename: file))
                    } else {
                        NavigationLink(name) {
                            LicenseTextView(title: name, filename: file)
                        }
                    }
                }
            } header: {
                WaddleSectionHeader("Licenses")
            }
        }
        .waddleScrollSurface()
        .navigationTitle("About")
        .accessibilityIdentifier("aboutView")
        .sheet(item: Binding(get: { host.presents ? shown.exportedZip.map(ExportedZip.init) : nil },
                             set: { if host.presents { shown.exportedZip = $0?.url } })) { zip in
            ShareSheet(items: [zip.url])
        }
        .alert("Export failed", isPresented: host.presented(
            { shown.exportError != nil }, dismiss: { shown.exportError = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shown.exportError ?? "")
        }
        // The query reaches github.com as the page loads, so the user reads
        // the literal values before tapping, not after.
        .alert("Report a bug on GitHub?", isPresented: host.presented(
            { shown.confirmBugReport }, dismiss: { shown.confirmBugReport = false }
        )) {
            Button("Open GitHub") { openURL(BugReport.url(facts: DeviceFacts.current)) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(BugReport.confirmationMessage(facts: DeviceFacts.current))
        }
        .sheet(item: Binding(get: { host.presents ? shown.feedbackMail.map(FeedbackSheet.init) : nil },
                             set: { if host.presents { shown.feedbackMail = $0?.composition } })) { sheet in
            MailComposeSheet(composition: sheet.composition) { shown.feedbackMail = nil }
                .ignoresSafeArea()
        }
        .alert("Mail isn't set up", isPresented: host.presented(
            { shown.mailUnavailable }, dismiss: { shown.mailUnavailable = false }
        )) {
            Button("Copy Address") { UIPasteboard.general.string = FeedbackMail.recipient }
            Button("Export Diagnostics") { exportDiagnostics() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Send your feedback to \(FeedbackMail.recipient) from any mail app. To include diagnostics, export the file and attach it yourself.")
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

    /// The mail sheet with the diagnostics file attached, or the alert when
    /// this device has no mail account. The file is built only when there is
    /// a sheet to attach it to.
    private func sendFeedback() {
        let canSendMail = MFMailComposeViewController.canSendMail()
        let facts = DeviceFacts.current
        let lines = DiagnosticsExporter.libraryLines(from: library)
        Task.detached(priority: .userInitiated) {
            DiagnosticsExporter.reclaimStaleExports()
            do {
                let outcome = try FeedbackMail.prepare(canSendMail: canSendMail, facts: facts) {
                    try DiagnosticsExporter.export(
                        diagnosticsDirectory: DiagnosticsPaths.directory,
                        libraryLines: lines)
                }
                await MainActor.run {
                    switch outcome {
                    case .compose(let composition): shown.feedbackMail = composition
                    case .unavailable: shown.mailUnavailable = true
                    }
                }
            } catch {
                await MainActor.run { shown.exportError = error.localizedDescription }
            }
        }
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
                await MainActor.run { shown.exportedZip = url }
            } catch {
                await MainActor.run { shown.exportError = error.localizedDescription }
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
                .font(Theme.Typography.mono)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.base)
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

/// The system mail sheet. The user sees the recipient, their own From
/// address and the attachment, and sends or cancels it; either way the sheet
/// goes and the app keeps nothing of what was written.
struct MailComposeSheet: UIViewControllerRepresentable {
    let composition: FeedbackMail.Composition
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(composition.recipients)
        controller.setSubject(composition.subject)
        controller.setMessageBody(composition.body, isHTML: false)
        for attachment in composition.attachments {
            if let data = try? Data(contentsOf: attachment.url) {
                controller.addAttachmentData(data, mimeType: attachment.mimeType,
                                             fileName: attachment.fileName)
            }
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController,
                                context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult,
                                   error: Error?) {
            onFinish()
        }
    }
}
