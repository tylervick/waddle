import SwiftUI

/// The Play tab: sectioned grid of everything directly launchable -- recently
/// played, base games (one-tap, no loadout required), and saved presets.
/// Replaces the preset-only loadout grid.
struct PlayView: View {
    let library: LibraryService
    @Binding var lastExitCode: Int32?

    @State private var recent: [PlayableItem] = []
    @State private var baseGames: [PlayableItem] = []
    @State private var presets: [PlayableItem] = []
    @State private var detailItem: PlayableItem?

    @State private var editorLoadout: Loadout?
    // Set by the detail page's Edit action instead of `editorLoadout`
    // directly: presenting the editor sheet must wait until the detail
    // sheet has fully dismissed (see `.sheet(item: $detailItem, onDismiss:)`
    // below) -- setting `editorLoadout` and dismissing the detail sheet in
    // the same synchronous pass is the same same-transaction dismiss/present
    // race Task 4 hit and fixed in cfaed69, just on the Edit path instead of
    // the create path.
    @State private var pendingEditLoadout: Loadout?
    @State private var showCreationFlow = false
    @AppStorage(TouchControlScheme.userDefaultsKey) private var touchScheme: TouchControlScheme = .defaultScheme
    @AppStorage(debugHUDUserDefaultsKey) private var debugHUD: Bool = false
    @State private var showControlFeel = false
    @State private var showAbout = false
    @State private var errorAlert: EngineErrorAlert?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Recently Played re-lists items that also live in Base
                    // Games/Presets below; those sections hold the
                    // contractual identifiers ("playFreedoom1",
                    // "loadout-<name>") that UITests look up expecting a
                    // single match, so this section's tiles get a
                    // non-canonical id instead of duplicating them.
                    section(title: "Recently Played", items: recent, canonicalID: false)
                    section(title: "Base Games", items: baseGames, canonicalID: true)
                    section(title: "Presets", items: presets, canonicalID: true)
                }
                .padding()
            }
            .navigationTitle("WADdle")
            .toolbar { toolbarContent }
            // .overlay, not .safeAreaInset -- a conditionally-empty
            // safeAreaInset directly above a ScrollView/LazyVGrid crashed
            // SwiftUI's layout engine here (HVGrid.minorGeometry, SwiftUI
            // internal, iOS 26.2 SDK); .overlay is the same pattern
            // ContentView already uses successfully for its own
            // conditional post-session labels.
            .overlay(alignment: .bottom) {
                if debugHUD {
                    Text("WADdle \(BuildInfo.commit) (\(BuildInfo.branch)) · built \(BuildInfo.builtAt)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("buildInfoLabel")
                }
            }
            .sheet(isPresented: $showControlFeel) {
                ControlFeelView()
            }
            .sheet(isPresented: $showAbout) {
                NavigationStack { AboutView(library: library) }
            }
            .sheet(isPresented: $showCreationFlow, onDismiss: refresh) {
                PresetCreationFlow(library: library)
            }
            .sheet(item: $editorLoadout, onDismiss: refresh) { loadout in
                LoadoutEditorView(library: library, existing: loadout)
            }
            .sheet(item: $detailItem, onDismiss: {
                // Promote the pending edit only after the detail sheet is
                // fully gone -- presenting `editorLoadout` here (rather than
                // in `onEdit` below) keeps the dismiss-then-present pair in
                // separate transactions.
                if let loadout = pendingEditLoadout {
                    pendingEditLoadout = nil
                    editorLoadout = loadout
                }
            }) { item in
                PlayableDetailView(item: item, library: library,
                                   onPlay: play,
                                   onEdit: { pendingEditLoadout = $0 },
                                   onChanged: refresh)
            }
            .alert(errorAlert?.title ?? "", isPresented: Binding(
                get: { errorAlert != nil }, set: { if !$0 { errorAlert = nil } }
            ), presenting: errorAlert) { _ in
                Button("OK") { errorAlert = nil }
            } message: { alert in
                Text([alert.engineMessage, alert.hint].compactMap { $0 }
                    .joined(separator: "\n\n"))
            }
            .onAppear(perform: refresh)
        }
    }

    // Split out of `body`: a toolbar this size inline was enough for the
    // Swift type checker to give up entirely ("failed to produce diagnostic
    // for expression") rather than report a real error.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            touchSchemeMenu
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                showCreationFlow = true
            } label: {
                Label("New Preset", systemImage: "plus")
            }
            .accessibilityIdentifier("newLoadoutButton")
        }
    }

    private var touchSchemeMenu: some View {
        Menu {
            Picker("Touch Controls", selection: $touchScheme) {
                Text("Classic").tag(TouchControlScheme.classic)
                Text("Modern").tag(TouchControlScheme.modern)
            }
            .accessibilityIdentifier("touchSchemePicker")

            Toggle("Show Debug Info", isOn: $debugHUD)
                .accessibilityIdentifier("debugHUDToggle")

            // Sliders can't render inside a Menu (UIMenu has no slider row),
            // so the tuning sliders live in a sheet opened from here.
            Button {
                showControlFeel = true
            } label: {
                Label("Control Feel…", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier("controlFeelButton")

            Button {
                showAbout = true
            } label: {
                Label("About", systemImage: "info.circle")
            }
            .accessibilityIdentifier("aboutButton")
        } label: {
            Label("Touch Controls", systemImage: "gearshape")
        }
        .accessibilityIdentifier("touchSchemeMenu")
    }

    @ViewBuilder
    private func section(title: String, items: [PlayableItem], canonicalID: Bool) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.headline)
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        tile(for: item, canonicalID: canonicalID)
                    }
                }
            }
        }
    }

    private func tile(for item: PlayableItem, canonicalID: Bool) -> some View {
        Button {
            play(item)
        } label: {
            PlayableTileView(item: item, subtitle: subtitle(for: item), library: library)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(canonicalID ? accessibilityID(for: item) : "recent-\(item.id)")
        .contextMenu {
            switch item {
            case .baseGame:
                Button("Details") { detailItem = item }
            case .preset(let loadout):
                Button("Details") { detailItem = item }
                Button("Edit") { editorLoadout = loadout }
                Button("Delete Preset & Saves", role: .destructive) {
                    try? library.deleteLoadout(loadout, deleteSaves: true)
                    refresh()
                }
                Button("Delete Preset, Keep Saves", role: .destructive) {
                    try? library.deleteLoadout(loadout, deleteSaves: false)
                    refresh()
                }
            }
        }
    }

    private func accessibilityID(for item: PlayableItem) -> String {
        if item.title == "Freedoom Phase 1" && item.isBaseGame {
            return "playFreedoom1"
        }
        switch item {
        case .baseGame:
            return item.id
        case .preset(let loadout):
            return "loadout-\(loadout.name)"
        }
    }

    private func subtitle(for item: PlayableItem) -> String {
        switch item {
        case .baseGame:
            return "Base game"
        case .preset(let loadout):
            let pwads = loadout.pwadIDs.compactMap { try? library.wad(id: $0)?.displayName }
            return pwads.isEmpty ? "Base game" : pwads.joined(separator: " + ")
        }
    }

    private func play(_ item: PlayableItem) {
        lastExitCode = nil
        do {
            let plan = try PlayableLauncher.prepare(item, library: library)
            lastExitCode = EngineSession.play(arguments: plan.arguments, scheme: plan.scheme)
            errorAlert = EngineErrorAlert.from(exitCode: lastExitCode ?? 0,
                                               engineMessage: EngineSession.lastErrorMessage)
        } catch {
            lastExitCode = EngineSession.ExitCode.argumentFailure
            errorAlert = EngineErrorAlert.from(exitCode: EngineSession.ExitCode.argumentFailure,
                                               engineMessage: "A file in this preset is missing from the library.")
        }
        refresh()
    }

    private func refresh() {
        recent = (try? library.recentlyPlayed(limit: 6)) ?? []
        baseGames = (try? library.baseGames().map(PlayableItem.baseGame)) ?? []
        presets = (try? library.presets().map(PlayableItem.preset)) ?? []
    }
}
