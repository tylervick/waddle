import SwiftUI
import UniformTypeIdentifiers

/// The Manage door (spec §3): the library workspace, pushed from the shelf
/// rather than sitting beside it as a tab. Holds everything that used to be
/// top-level — the grouped file list with its Base Games / Mods / Patches
/// taxonomy, Import, preset creation and editing — plus Hidden from Shelf,
/// where an item removed from the shelf is restored.
///
/// No `NavigationStack` of its own: it is pushed into the shelf's.
struct LibraryView: View {
    let library: LibraryService
    let importer: ImportService
    /// Launching from a Details page opened here goes back through the shelf's
    /// own launcher, so a session started from Manage still reports its exit
    /// code where every other session does.
    let onPlay: (PlayableItem, LaunchMode) -> Void

    @Environment(\.openURL) private var openURL
    @State private var groups: [LibraryGroup] = []
    @State private var presets: [Loadout] = []
    @State private var hidden: [PlayableItem] = []
    @State private var showImporter = false
    @State private var showCreationFlow = false
    @State private var editorLoadout: Loadout?
    @State private var detailItem: PlayableItem?
    @State private var pendingEditLoadout: Loadout?
    @State private var lastOutcome: ImportOutcome?
    @State private var deleteBlocked: [BlockedFile] = []

    /// One file a delete refused, with the presets holding it. A batch blocks
    /// on several files at once, and the alert has to say which file belongs to
    /// which presets — a flat list of preset names cannot, because it does not
    /// even record how many files are involved.
    struct BlockedFile: Equatable {
        let filename: String
        var presets: [String]
    }

    /// The Files app opens container paths handed to it under its own URL
    /// scheme; only file URLs have a Files-app location.
    static func filesAppURL(for fileURL: URL) -> URL? {
        guard fileURL.isFileURL,
              var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = "shareddocuments"
        return components.url
    }

    /// Merges preset names, dropping repeats — one preset commonly holds
    /// several of the WADs being deleted, and two loadouts may carry the same
    /// name, so the same name can arrive more than once.
    static func blockedNames(_ existing: [String], adding names: [String]) -> [String] {
        var merged = existing
        for name in names where !merged.contains(name) { merged.append(name) }
        return merged
    }

    /// A multi-row delete blocks on each row separately, so blocked files
    /// accumulate across the whole batch — one entry per file, keeping each
    /// file's own presets with it rather than pooling them all together.
    static func blockedFiles(_ existing: [BlockedFile],
                             adding presets: [String],
                             for filename: String) -> [BlockedFile] {
        var merged = existing
        if let index = merged.firstIndex(where: { $0.filename == filename }) {
            merged[index].presets = blockedNames(merged[index].presets, adding: presets)
        } else {
            merged.append(BlockedFile(filename: filename,
                                      presets: blockedNames([], adding: presets)))
        }
        return merged
    }

    /// Runs a whole delete batch, accumulating one entry per row the library
    /// refused. This lives here — static, taking the service — rather than
    /// inline in the view because `deleteBlocked` is `@State` and the repo has
    /// no view-testing harness: with the loop inside the view, reverting the
    /// accumulation to a plain overwrite left the entire suite green, so the
    /// only thing pinned was the helper it happened to call.
    @MainActor
    static func deleting(_ wads: [WADFile],
                         from library: LibraryService,
                         blocked existing: [BlockedFile]) -> [BlockedFile] {
        var blocked = existing
        for wad in wads {
            do {
                try library.deleteWAD(wad, force: false)
            } catch LibraryError.wadReferencedByLoadouts(let names) {
                blocked = blockedFiles(blocked, adding: names, for: wad.filename)
            } catch {}
        }
        return blocked
    }

    /// The "File in use" alert's body: one line per blocked file, so the reader
    /// can tell which file to remove from which presets, then a closing
    /// instruction that agrees in number with what is actually listed.
    static func blockedMessage(for files: [BlockedFile]) -> String {
        guard let only = files.first else { return "" }
        let lines = files.map { "\($0.filename) — used by \($0.presets.joined(separator: ", "))" }
        let closing: String
        if files.count > 1 {
            closing = "Remove each file from those presets first."
        } else if only.presets.count == 1 {
            closing = "Remove it from that preset first."
        } else {
            closing = "Remove it from those presets first."
        }
        return (lines + [closing]).joined(separator: "\n")
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section {
                    ForEach(group.wads, id: \.id) { wad in
                        row(for: wad)
                    }
                    .onDelete { offsets in
                        delete(offsets.map { group.wads[$0] })
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    if group.kind == .deh {
                        Text("Patches modify a base game and aren't playable on their own — add them to a preset's Contents.")
                    }
                }
            }
            presetsSection
            hiddenSection
        }
        .accessibilityIdentifier("manageScreen")
        .navigationTitle("Manage")
        .toolbar {
            Button {
                showCreationFlow = true
            } label: {
                Label("New Preset", systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("newLoadoutButton")

            Button {
                showImporter = true
            } label: {
                Label("Import", systemImage: "plus")
            }
            .accessibilityIdentifier("importButton")
        }
        .sheet(isPresented: $showCreationFlow, onDismiss: refresh) {
            PresetCreationFlow(library: library)
        }
        .sheet(item: $editorLoadout, onDismiss: refresh) { loadout in
            LoadoutEditorView(library: library, existing: loadout)
        }
        .sheet(item: $detailItem, onDismiss: {
            // Promote the pending edit only once the detail sheet is fully
            // gone — presenting the editor in the same synchronous pass as
            // the dismiss is the transaction race cfaed69 fixed on the
            // create path, and `ShelfView` avoids the same way.
            if let loadout = pendingEditLoadout {
                pendingEditLoadout = nil
                editorLoadout = loadout
            }
            refresh()
        }) { item in
            PlayableDetailView(item: item, library: library,
                               onPlay: { onPlay($0, $1) },
                               onEdit: { pendingEditLoadout = $0 },
                               onChanged: refresh)
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let outcome = importer.importFiles(at: urls)
                lastOutcome = outcome
                ImportNotices.shared.post(outcome: outcome)
                refresh()
            }
        }
        .alert("Import complete", isPresented: outcomeAlertBinding, presenting: lastOutcome) { _ in
            Button("OK") { lastOutcome = nil }
        } message: { outcome in
            Text(summary(of: outcome))
        }
        .alert("File in use", isPresented: deleteBlockedBinding) {
            Button("OK") { deleteBlocked = [] }
        } message: {
            Text(Self.blockedMessage(for: deleteBlocked))
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in refresh() }
    }

    /// Presets, listed as presets — the one place that does. A row opens the
    /// same `PlayableDetailView` a tile's Details opens (spec §3's
    /// shared-component rule: one component, two entrances), and editing is
    /// that page's own Edit button rather than a second route to the editor.
    @ViewBuilder
    private var presetsSection: some View {
        if !presets.isEmpty {
            Section("Presets") {
                ForEach(presets, id: \.id) { loadout in
                    Button {
                        detailItem = .preset(loadout)
                    } label: {
                        HStack {
                            Text(loadout.name)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    // Deliberately not "loadout-<name>": the shelf's tiles hold
                    // that identifier and stay in the hierarchy behind this
                    // push, so reusing it here would make every UI-test lookup
                    // of a tile ambiguous.
                    .accessibilityIdentifier("managePreset-\(loadout.name)")
                }
            }
        }
    }

    /// Hidden from Shelf (spec §3/§4): items removed from the shelf, each with
    /// Restore. The row, its file and its saves all still exist — hiding is a
    /// flag, which is what keeps the seeder from resurrecting a bundled row
    /// under a fresh UUID.
    @ViewBuilder
    private var hiddenSection: some View {
        if !hidden.isEmpty {
            Section("Hidden from Shelf") {
                ForEach(hidden) { item in
                    HStack {
                        Text(item.title)
                        Spacer()
                        Button("Restore") {
                            try? library.restore(item)
                            refresh()
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("restore-\(item.id)")
                    }
                    .accessibilityIdentifier("hiddenRow-\(item.id)")
                }
            }
        }
    }

    private func row(for wad: WADFile) -> some View {
        let status = library.fileStatus(for: wad)
        let size = library.fileSize(for: wad)
        return VStack(alignment: .leading, spacing: 2) {
            Text(wad.filename)
            HStack(spacing: 4) {
                if let size {
                    Text(size, format: .byteCount(style: .file))
                    Text("·")
                }
                Text(statusLabel(status))
                    .foregroundStyle(status == .missing ? AnyShapeStyle(.red)
                                                        : AnyShapeStyle(.secondary))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("libraryRow-\(wad.filename)")
        .deleteDisabled(wad.isBundled)
        .contextMenu {
            if status == .imported,
               let url = Self.filesAppURL(for: library.fileURL(for: wad)) {
                Button {
                    openURL(url)
                } label: {
                    Label("Show in Files", systemImage: "folder")
                }
            }
            if !wad.isBundled {
                Button(role: .destructive) {
                    delete([wad])
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func statusLabel(_ status: LibraryFileStatus) -> String {
        switch status {
        case .bundled: return "Bundled"
        case .imported: return "Imported"
        case .missing: return "Missing"
        }
    }

    private var importTypes: [UTType] {
        var types: [UTType] = [.zip]
        if let wad = UTType(filenameExtension: "wad") { types.append(wad) }
        if let deh = UTType(filenameExtension: "deh") { types.append(deh) }
        if let bex = UTType(filenameExtension: "bex") { types.append(bex) }
        return types
    }

    private var outcomeAlertBinding: Binding<Bool> {
        Binding(get: { lastOutcome != nil }, set: { if !$0 { lastOutcome = nil } })
    }

    private var deleteBlockedBinding: Binding<Bool> {
        Binding(get: { !deleteBlocked.isEmpty }, set: { if !$0 { deleteBlocked = [] } })
    }

    private func summary(of outcome: ImportOutcome) -> String {
        var lines: [String] = []
        if !outcome.imported.isEmpty { lines.append("Imported: \(outcome.imported.joined(separator: ", "))") }
        if !outcome.duplicates.isEmpty { lines.append("Already in library: \(outcome.duplicates.joined(separator: ", "))") }
        for (file, reason) in outcome.rejected { lines.append("\(file): \(reason)") }
        return lines.isEmpty ? "Nothing imported." : lines.joined(separator: "\n")
    }

    private func delete(_ wads: [WADFile]) {
        deleteBlocked = Self.deleting(wads, from: library, blocked: deleteBlocked)
        refresh()
    }

    private func refresh() {
        groups = (try? library.libraryGroups()) ?? []
        presets = (try? library.presets()) ?? []
        hidden = (try? library.hiddenItems()) ?? []
    }
}
