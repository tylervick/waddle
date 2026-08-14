import SwiftUI

/// The single Read/Update/Delete surface for any playable item -- base game
/// *or* preset -- reached from the Play grid's "Details" context action. Same
/// layout for both; editability differs (see the design spec's "The detail
/// page" section). Follows the `NavigationStack { Form { ... } }` pattern
/// used by `LoadoutEditorView`.
struct PlayableDetailView: View {
    let item: PlayableItem
    let library: LibraryService
    let onPlay: (PlayableItem, LaunchMode) -> Void
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
         onPlay: @escaping (PlayableItem, LaunchMode) -> Void,
         onEdit: @escaping (Loadout) -> Void,
         onChanged: @escaping () -> Void) {
        self.item = item
        self.library = library
        self.onPlay = onPlay
        self.onEdit = onEdit
        self.onChanged = onChanged
        _scheme = State(initialValue: item.schemeOverrideRaw.flatMap(TouchControlScheme.init(rawValue:)))
    }

    /// The saves-directory key for this item -- see `PlayableItem.savesKey`,
    /// which `PlayableLauncher` keys the launch off too.
    private var savesKey: UUID { item.savesKey }

    /// Non-nil when this item has a save the engine can boot straight into, in
    /// which case the header offers Continue. Derived from `saves`, so it
    /// tracks a deletion in `savesSection` without a second directory read.
    private var continuableSlot: Int? {
        EngineSaveSlot.newestLoadGameArgument(in: saves)
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
            TitleArtView(item: item, library: library)
            Text(item.title).font(.title2.bold())
            // With a resumable save, Continue takes the prominent slot and Play
            // becomes the explicit "New Game" half of the pair -- the
            // predecessor's RESUME/NEW split. With no saves the `else` branch
            // is exactly the single prominent Play button this has always been.
            if continuableSlot != nil {
                Button {
                    onPlay(item, .continueNewest)
                } label: {
                    Label("Continue", systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("detailContinueButton")

                Button {
                    onPlay(item, .newGame)
                } label: {
                    Label("New Game", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("detailPlayButton")
            } else {
                Button {
                    onPlay(item, .newGame)
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("detailPlayButton")
            }
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
