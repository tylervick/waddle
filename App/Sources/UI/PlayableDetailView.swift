import SwiftUI

/// The single Read/Update/Delete surface for any playable item -- base game
/// *or* preset -- reached from the Play grid's "Details" context action. Same
/// layout for both; editability differs (see the design spec's "The detail
/// page" section). Follows the `NavigationStack { Form { ... } }` pattern
/// used by `LoadoutEditorView`.
struct PlayableDetailView: View {
    let item: PlayableItem
    let library: LibraryService
    let onPlay: (PlayableItem) -> Void
    let onEdit: (Loadout) -> Void
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Mirrors the item's `schemeOverrideRaw` for the Controls picker.
    /// Written back through `LibraryService.setSchemeOverride` on change --
    /// see the type-level doc comment on `PlayableItem.schemeOverrideRaw`.
    @State private var scheme: TouchControlScheme?
    @State private var saves: [LibraryService.SaveSlot] = []
    @State private var showCreatePresetFromBase = false

    init(item: PlayableItem, library: LibraryService,
         onPlay: @escaping (PlayableItem) -> Void,
         onEdit: @escaping (Loadout) -> Void,
         onChanged: @escaping () -> Void) {
        self.item = item
        self.library = library
        self.onPlay = onPlay
        self.onEdit = onEdit
        self.onChanged = onChanged
        _scheme = State(initialValue: item.schemeOverrideRaw.flatMap(TouchControlScheme.init(rawValue:)))
    }

    /// The saves-directory key for this item: a base game keys its saves off
    /// the IWAD's own id, a preset off the Loadout's id (Task 6 reconciles
    /// this against the engine's actual save filenames).
    private var savesKey: UUID {
        switch item {
        case .baseGame(let wad): return wad.id
        case .preset(let loadout): return loadout.id
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                contentsSection
                controlsSection
                savesSection
                footerSection
            }
            .navigationTitle(item.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { saves = library.saveSlots(forKey: savesKey) }
            .sheet(isPresented: $showCreatePresetFromBase, onDismiss: onChanged) {
                if case .baseGame(let wad) = item {
                    LoadoutEditorView(library: library, existing: nil, seedIWAD: wad)
                }
            }
        }
    }

    // MARK: Sections
    //
    // Split out of `body` -- a Form this size inline is enough for the Swift
    // type checker to give up entirely (see PlayView.toolbarContent's own
    // note on the same limit).

    private var headerSection: some View {
        Section {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .aspectRatio(1.6, contentMode: .fit)
                .overlay(
                    Image(systemName: "flame.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                )
            Text(item.title).font(.title2.bold())
            Button {
                onPlay(item)
            } label: {
                Label("Play", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("detailPlayButton")
        }
    }

    @ViewBuilder
    private var contentsSection: some View {
        Section("Contents") {
            switch item {
            case .baseGame(let wad):
                Text("Base: \(wad.displayName)")
            case .preset(let loadout):
                LabeledContent("Base", value: (try? library.wad(id: loadout.iwadID))?.displayName ?? "?")
                LabeledContent("Mods", value: modsSummary(loadout))
                LabeledContent("Patches", value: patchesSummary(loadout))
                LabeledContent("Compat", value: loadout.complevel ?? "Auto")
                Button("Edit") {
                    onEdit(loadout)
                    dismiss()
                }
                .accessibilityIdentifier("detailEditButton")
            }
        }
    }

    private var controlsSection: some View {
        Section("Controls") {
            Picker("Layout", selection: $scheme) {
                Text("Default (\(TouchControlScheme.current().displayLabel))")
                    .tag(TouchControlScheme?.none)
                Text("Classic").tag(TouchControlScheme?.some(.classic))
                Text("Modern").tag(TouchControlScheme?.some(.modern))
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("detailSchemePicker")
            .onChange(of: scheme) { _, newValue in
                applySchemeOverride(newValue?.rawValue)
            }
        }
    }

    @ViewBuilder
    private var savesSection: some View {
        Section("Saves") {
            if saves.isEmpty {
                Text("No saves yet").foregroundStyle(.secondary)
            } else {
                ForEach(saves) { slot in
                    LabeledContent(slot.id,
                                  value: slot.modified.formatted(date: .abbreviated, time: .shortened))
                }
                .onDelete(perform: deleteSaves)
            }
        }
    }

    @ViewBuilder
    private var footerSection: some View {
        switch item {
        case .baseGame:
            Section {
                Button("Create preset from this") {
                    showCreatePresetFromBase = true
                }
                .accessibilityIdentifier("createPresetFromBaseButton")
            }
        case .preset(let loadout):
            Section {
                Button("Delete Preset & Saves", role: .destructive) {
                    try? library.deleteLoadout(loadout, deleteSaves: true)
                    onChanged()
                    dismiss()
                }
                Button("Delete Preset, Keep Saves", role: .destructive) {
                    try? library.deleteLoadout(loadout, deleteSaves: false)
                    onChanged()
                    dismiss()
                }
            }
        }
    }

    // MARK: Actions

    private func applySchemeOverride(_ raw: String?) {
        switch item {
        case .baseGame(let wad):
            try? library.setSchemeOverride(raw, forBaseGame: wad)
        case .preset(let loadout):
            try? library.setSchemeOverride(raw, forPreset: loadout)
        }
        onChanged()
    }

    private func deleteSaves(at offsets: IndexSet) {
        for index in offsets {
            library.deleteSave(saves[index], forKey: savesKey)
        }
        saves = library.saveSlots(forKey: savesKey)
    }

    private func modsSummary(_ loadout: Loadout) -> String {
        let names = loadout.pwadIDs.compactMap { try? library.wad(id: $0)?.displayName }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }

    private func patchesSummary(_ loadout: Loadout) -> String {
        let names = loadout.dehIDs.compactMap { try? library.wad(id: $0)?.displayName }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }
}
