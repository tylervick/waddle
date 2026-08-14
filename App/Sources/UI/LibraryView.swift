import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let library: LibraryService
    let importer: ImportService

    @Environment(\.openURL) private var openURL
    @State private var groups: [LibraryGroup] = []
    @State private var showImporter = false
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
        NavigationStack {
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
            }
            .navigationTitle("Library")
            .toolbar {
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
                .accessibilityIdentifier("importButton")
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
    }
}
