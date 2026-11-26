import SwiftUI

/// **Add → From a Link…** (#500): a field for an `https` link to a `.wad`,
/// `.deh`, `.bex` or `.zip`, and a download with progress and a Cancel. It
/// closes once the download ends; the import notice then says what
/// happened, as it does for a file picked in Files.
///
/// `model` is the shelf's, so a link dropped on the shelf (#550) opens this
/// sheet with the link filled in and its download already running, and
/// several dropped links read "1 of 3".
struct LinkImportSheet: View {
    let model: LinkImport
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://", text: $text)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit(download)
                        .disabled(model.isBusy)
                        .accessibilityLabel("Link")
                        .accessibilityIdentifier("linkImportField")
                    if !model.isBusy {
                        // No prompt to paste: the system button reads the
                        // clipboard only when tapped.
                        PasteButton(payloadType: URL.self) { urls in
                            if let url = urls.first { text = url.absoluteString }
                        }
                    }
                } footer: {
                    Text("Waddle downloads the file at this link and adds it to your library. The link must start with https:// and lead to a .wad, .deh, .bex or .zip file of up to \(LinkDownloader.maxBytes / (1024 * 1024)) MB.")
                }
                if let invalid = model.invalidLink {
                    Section {
                        Text(invalid)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("linkImportError")
                    }
                }
                if model.isBusy {
                    Section {
                        progress
                        Button("Cancel Download", role: .destructive) { model.cancel() }
                            .disabled(model.phase == .importing)
                            .accessibilityIdentifier("linkImportCancel")
                    }
                }
            }
            .navigationTitle("Add From a Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Download", action: download)
                        .disabled(model.isBusy || text.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("linkImportDownload")
                }
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .onAppear { showCurrent(model.current) }
        .onChange(of: model.current) { _, url in showCurrent(url) }
        .onDisappear { model.cancel() }
    }

    /// Fills the field with the link downloading, whoever started it.
    private func showCurrent(_ url: URL?) {
        if let url { text = url.absoluteString }
    }

    /// "Downloading…", or "Downloading 1 of 3…" while several are queued.
    private var downloadingTitle: String {
        guard let position = model.position, position.count > 1 else { return "Downloading…" }
        return "Downloading \(position.index) of \(position.count)…"
    }

    @ViewBuilder
    private var progress: some View {
        switch model.phase {
        case .downloading(let received, let expected?) where expected > 0:
            ProgressView(value: Double(received), total: Double(expected)) {
                Text(downloadingTitle)
            } currentValueLabel: {
                Text(verbatim: "\(Self.megabytes(received)) of \(Self.megabytes(expected))")
            }
        case .downloading(let received, _):
            LabeledContent {
                Text(verbatim: Self.megabytes(received))
            } label: {
                Label {
                    Text(downloadingTitle)
                } icon: {
                    ProgressView()
                }
            }
        case .importing, .idle:
            ProgressView("Adding to your library…")
        }
    }

    private func download() {
        model.start(text) { dismiss() }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
