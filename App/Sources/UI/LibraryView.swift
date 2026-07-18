import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    let library: LibraryService
    let importer: ImportService

    @State private var wads: [WADFile] = []
    @State private var showImporter = false
    @State private var lastOutcome: ImportOutcome?
    @State private var deleteBlocked: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(wads, id: \.id) { wad in
                    row(for: wad)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("Library")
            .toolbar {
                Button {
                    showImporter = true
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
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
            .alert("WAD in use", isPresented: deleteBlockedBinding) {
                Button("OK") { deleteBlocked = [] }
            } message: {
                Text("Used by: \(deleteBlocked.joined(separator: ", ")). Remove it from those loadouts first.")
            }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in refresh() }
        }
    }

    /// PWAD rows get a "New Loadout" shortcut (swipe + context menu). Custom
    /// swipe actions suppress onDelete's automatic swipe on that row, so PWAD
    /// rows also carry an explicit trailing Delete to keep parity.
    @ViewBuilder
    private func row(for wad: WADFile) -> some View {
        let base = HStack {
            VStack(alignment: .leading) {
                Text(wad.displayName)
                Text(wad.isBundled ? "Bundled" : wad.filename)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(wad.kindRaw)
                .font(.caption.bold())
                .padding(4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
        .deleteDisabled(wad.isBundled)

        if wad.kindRaw == WADKind.pwad.rawValue {
            base
                .swipeActions(edge: .leading) { newLoadoutButton(for: wad) }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        delete(wad)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .contextMenu { newLoadoutButton(for: wad) }
        } else {
            base
        }
    }

    private func newLoadoutButton(for wad: WADFile) -> some View {
        Button {
            createLoadout(from: wad)
        } label: {
            Label("New Loadout", systemImage: "plus.rectangle.on.rectangle")
        }
        .tint(.blue)
        .accessibilityIdentifier("newLoadoutFromPWAD-\(wad.displayName)")
    }

    private func createLoadout(from wad: WADFile) {
        guard let iwad = try? library.suggestedIWAD(for: wad) else { return }
        guard (try? library.createLoadout(name: wad.displayName, iwadID: iwad.id,
                                          pwadIDs: [wad.id], dehIDs: [])) != nil else { return }
        ImportNotices.shared.post(
            message: "Created loadout \(wad.displayName) — find it in Play")
        NotificationCenter.default.post(name: .libraryDidChange, object: nil)
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

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            delete(wads[index])
        }
    }

    private func delete(_ wad: WADFile) {
        do {
            try library.deleteWAD(wad, force: false)
        } catch LibraryError.wadReferencedByLoadouts(let names) {
            deleteBlocked = names
        } catch {}
        refresh()
    }

    private func refresh() {
        wads = (try? library.allWADs()) ?? []
    }
}
