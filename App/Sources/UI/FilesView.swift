import SwiftUI

/// Storage, and nothing else (spec §3.4): every file on disk grouped by role,
/// with its size, where it came from, and which games load it. Reached from
/// Settings; has no import button — the shelf's Add is the one door.
struct FilesView: View {
    let library: LibraryService

    @Environment(\.openURL) private var openURL
    @State private var groups: [FileGroup] = []
    @State private var usedBy: [UUID: [Game]] = [:]
    @State private var deleteBlocked: [BlockedFile] = []

    /// One file a delete refused, with the games holding it. A batch blocks on
    /// several files at once, and the alert has to say which file belongs to
    /// which games.
    struct BlockedFile: Equatable {
        let filename: String
        var games: [String]
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

    /// Merges game names, dropping repeats.
    static func blockedNames(_ existing: [String], adding names: [String]) -> [String] {
        var merged = existing
        for name in names where !merged.contains(name) { merged.append(name) }
        return merged
    }

    /// One entry per blocked file across a batch, each keeping its own games.
    static func blockedFiles(_ existing: [BlockedFile],
                             adding games: [String],
                             for filename: String) -> [BlockedFile] {
        var merged = existing
        if let index = merged.firstIndex(where: { $0.filename == filename }) {
            merged[index].games = blockedNames(merged[index].games, adding: games)
        } else {
            merged.append(BlockedFile(filename: filename, games: blockedNames([], adding: games)))
        }
        return merged
    }

    /// Runs a whole delete batch, accumulating one entry per refused row. Static
    /// and service-taking so it can be tested without a view harness.
    @MainActor
    static func deleting(_ wads: [WADFile],
                         from library: LibraryService,
                         blocked existing: [BlockedFile]) -> [BlockedFile] {
        var blocked = existing
        for wad in wads {
            do {
                try library.deleteWAD(wad)
            } catch LibraryError.wadInUse(let names) {
                blocked = blockedFiles(blocked, adding: names, for: wad.filename)
            } catch {}
        }
        return blocked
    }

    /// The "File in use" alert's body: one line per blocked file, then a closing
    /// instruction that agrees in number with what is listed.
    static func blockedMessage(for files: [BlockedFile]) -> String {
        guard let only = files.first else { return "" }
        let lines = files.map { "\($0.filename) — used by \($0.games.joined(separator: ", "))" }
        let closing: String
        if files.count > 1 {
            closing = "Remove each file from those games first."
        } else if only.games.count == 1 {
            closing = "Remove it from that game first."
        } else {
            closing = "Remove it from those games first."
        }
        return (lines + [closing]).joined(separator: "\n")
    }

    var body: some View {
        List {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.wads, id: \.id) { wad in
                        row(for: wad)
                    }
                    .onDelete { offsets in
                        delete(offsets.map { group.wads[$0] })
                    }
                }
            }
        }
        .waddleScrollSurface()
        .accessibilityIdentifier("filesScreen")
        .navigationTitle("Files")
        .navigationBarTitleDisplayMode(.inline)
        .alert("File in use", isPresented: Binding(
            get: { !deleteBlocked.isEmpty }, set: { if !$0 { deleteBlocked = [] } }
        )) {
            Button("OK") { deleteBlocked = [] }
        } message: {
            Text(Self.blockedMessage(for: deleteBlocked))
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in refresh() }
    }

    private func row(for wad: WADFile) -> some View {
        let status = library.fileStatus(for: wad)
        let size = library.fileSize(for: wad)
        let games = usedBy[wad.id] ?? []
        let unpaired = games.contains { $0.baseID == nil }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(wad.filename)
                if unpaired {
                    Text("no base")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.red.opacity(0.35), in: Capsule())
                }
            }
            HStack(spacing: 4) {
                if let size {
                    Text(size, format: .byteCount(style: .file))
                    Text("·")
                }
                Text(statusLabel(status))
                    .foregroundStyle(status == .missing ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(GamePage.usedByLine(gameNames: games.map(\.name)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fileRow-\(wad.filename)")
        .deleteDisabled(wad.isBundled)
        .contextMenu {
            if status == .imported, let url = Self.filesAppURL(for: library.fileURL(for: wad)) {
                Button { openURL(url) } label: { Label("Show in Files", systemImage: "folder") }
            }
            if !wad.isBundled {
                Button(role: .destructive) { delete([wad]) } label: { Label("Delete", systemImage: "trash") }
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

    private func delete(_ wads: [WADFile]) {
        deleteBlocked = Self.deleting(wads, from: library, blocked: deleteBlocked)
        refresh()
    }

    private func refresh() {
        groups = (try? library.fileGroups()) ?? []
        var map: [UUID: [Game]] = [:]
        for group in groups {
            for wad in group.wads {
                map[wad.id] = (try? library.gamesUsing(fileID: wad.id)) ?? []
            }
        }
        usedBy = map
    }
}
