import SwiftUI

/// **Add → From Sources…** (#502): the saved places to get games from. A tap
/// on a source downloads its file through the link import (#500), with
/// progress in the row and a Cancel; the sheet closes once the download
/// ends and the import notice says what happened, as From a Link… does.
///
/// Players add their own sources (a name and an `https` link to a file) and
/// delete any source; a deleted shipped source (Freedoom) comes back with
/// Restore. Only file sources appear: a page source needs #501's web view,
/// so none can be made or listed yet.
struct SourcesSheet: View {
    @State private var store: SourceStore
    @State private var model: LinkImport
    /// The source whose download is running, for the row's progress.
    @State private var downloading: Source.ID?
    @State private var showAdd = false
    /// Held here rather than left to the list, so a row knows not to
    /// download while the list is being edited.
    @State private var editMode: EditMode = .inactive
    @Environment(\.dismiss) private var dismiss

    init(importer: ImportService, store: SourceStore = SourceStore()) {
        _store = State(initialValue: store)
        _model = State(initialValue: LinkImport(importer: importer))
    }

    private var sources: [Source] { store.sources.filter { $0.kind == .file } }

    var body: some View {
        NavigationStack {
            List {
                if sources.isEmpty {
                    // Restore first: at the largest text sizes the empty
                    // state alone fills an iPad form sheet or a closed Duo,
                    // and a Restore below it was out of sight.
                    restoreSection
                    ContentUnavailableView {
                        Label("No Sources", systemImage: "tray")
                    } description: {
                        Text("Add a link to a game file you want to download again later.")
                    }
                    .accessibilityIdentifier("sourcesEmpty")
                } else {
                    Section {
                        ForEach(sources) { source in
                            row(source)
                        }
                        // Swipe to delete, and Edit's delete buttons: taps
                        // alone reach it, where a swipe cannot (an open
                        // iPhone Duo, Switch Control).
                        .onDelete { offsets in
                            for index in offsets { store.delete(sources[index]) }
                            if sources.isEmpty { editMode = .inactive }
                        }
                        .deleteDisabled(model.isBusy)
                    } footer: {
                        Text(footer)
                    }
                }
                if !sources.isEmpty {
                    restoreSection
                }
                if model.isBusy {
                    Section {
                        Button("Cancel Download", role: .destructive) { model.cancel() }
                            .disabled(model.phase == .importing)
                            .accessibilityIdentifier("sourceDownloadCancel")
                    }
                }
            }
            .environment(\.editMode, $editMode)
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // "Close", not "Done": Edit's own button reads Done.
                    Button("Close") {
                        model.cancel()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    if !sources.isEmpty || editMode.isEditing {
                        Button(editMode.isEditing ? "Done" : "Edit") {
                            withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                        }
                        .disabled(model.isBusy)
                        .accessibilityIdentifier("editSources")
                    }
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Source", systemImage: "plus")
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("addSource")
                }
            }
            .navigationDestination(isPresented: $showAdd) {
                AddSourceView(store: store)
            }
        }
        .interactiveDismissDisabled(model.isBusy)
        .onDisappear { model.cancel() }
    }

    /// Shipped sources the player deleted, each with its Restore.
    @ViewBuilder
    private var restoreSection: some View {
        if !store.deletedShipped.isEmpty {
            Section {
                ForEach(store.deletedShipped) { source in
                    Button {
                        store.restore(source)
                    } label: {
                        Label("Restore \(source.name)", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("restoreSource-\(source.name)")
                }
            }
        }
    }

    /// The pin is promised only while a shipped source is listed: a
    /// player's own source, whatever its name, is not checked.
    private var footer: String {
        let tap = "Tap a source to download it into your library."
        guard sources.contains(where: \.isShipped) else { return tap }
        return tap + " Sources that come with Waddle are checked against the file their project published before they are added."
    }

    /// The row's second line: where it downloads from, and how much, when
    /// that is known before the tap.
    private static func detail(_ source: Source) -> String {
        let host = source.url.host() ?? source.url.absoluteString
        guard let bytes = source.byteCount else { return host }
        return "\(host) · \(megabytes(bytes))"
    }

    private func row(_ source: Source) -> some View {
        Button {
            download(source)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name)
                        .foregroundStyle(.primary)
                    Text(verbatim: Self.detail(source))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if downloading == source.id {
                        progress
                    }
                }
                Spacer(minLength: 0)
                if downloading != source.id {
                    Image(systemName: "arrow.down.circle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy || editMode.isEditing)
        .accessibilityHint("Downloads it into your library")
        .accessibilityIdentifier("source-\(source.name)")
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { store.delete(source) }
        }
    }

    @ViewBuilder
    private var progress: some View {
        switch model.phase {
        case .downloading(let received, let expected?) where expected > 0:
            ProgressView(value: Double(received), total: Double(expected)) {
                EmptyView()
            } currentValueLabel: {
                Text(verbatim: "\(Self.megabytes(received)) of \(Self.megabytes(expected))")
            }
        case .downloading(let received, _):
            Text(verbatim: "Downloading… \(Self.megabytes(received))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .importing, .idle:
            Text("Adding to your library…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func download(_ source: Source) {
        if model.start(source, onFinish: {
            downloading = nil
            dismiss()
        }) {
            downloading = source.id
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A player's own source: a name and an `https` link to one file. The link
/// is checked the way From a Link… checks it, and a refusal stays on screen
/// for a fix.
private struct AddSourceView: View {
    let store: SourceStore
    @State private var name = ""
    @State private var link = ""
    @State private var invalid: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("sourceNameField")
                TextField("https://", text: $link)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityLabel("Link")
                    .accessibilityIdentifier("sourceLinkField")
            } footer: {
                Text("A link that starts with https:// and leads to a .wad, .deh, .bex or .zip file. Tap the source later to download it.")
            }
            if let invalid {
                Section {
                    Text(invalid)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("sourceLinkError")
                }
            }
        }
        .navigationTitle("Add Source")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("saveSource")
            }
        }
    }

    private func save() {
        switch store.add(name: name, link: link) {
        case .success:
            dismiss()
        case .failure(let error):
            invalid = error.reason
        }
    }
}
