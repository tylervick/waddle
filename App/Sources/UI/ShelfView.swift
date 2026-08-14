import SwiftUI

/// The home screen (spec §§2–3): a Continue hero, one adaptive grid of every
/// playable item, and two doors — a gear for player settings and Manage for the
/// library workspace. Replaces the Play/Library `TabView`; management is
/// reachable but never on the primary path.
///
/// Composition is decided entirely by `LibraryService.shelfItems()` and the
/// pure functions in `Shelf`, which is what the hermetic tests exercise.
struct ShelfView: View {
    let library: LibraryService
    let importer: ImportService
    @Binding var lastExitCode: Int32?

    @State private var items: [PlayableItem] = []
    @State private var heroItem: PlayableItem?
    @State private var detailItem: PlayableItem?
    /// The item whose tap opened the Continue / New Game / Details sheet.
    @State private var actionItem: PlayableItem?

    @State private var editorLoadout: Loadout?
    // Presenting the editor sheet must wait until the detail sheet has fully
    // dismissed (see `.sheet(item: $detailItem, onDismiss:)` below): setting
    // `editorLoadout` and dismissing the detail sheet in the same synchronous
    // pass is a same-transaction dismiss/present race (fixed once in cfaed69).
    @State private var pendingEditLoadout: Loadout?
    @State private var showPlayerSettings = false
    @AppStorage(debugHUDUserDefaultsKey) private var debugHUD: Bool = false
    @State private var errorAlert: EngineErrorAlert?

    private let columns = [GridItem(.adaptive(minimum: 200), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let heroItem {
                    hero(for: heroItem)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(items) { item in
                        tile(for: item)
                    }
                }
            }
            .padding()
        }
        .navigationTitle("WADdle")
        .toolbar { toolbarContent }
        // .overlay, not .safeAreaInset -- a conditionally-empty safeAreaInset
        // directly above a ScrollView/LazyVGrid crashed SwiftUI's layout engine
        // here (HVGrid.minorGeometry, SwiftUI internal, iOS 26.2 SDK).
        .overlay(alignment: .bottom) {
            if debugHUD {
                Text("WADdle \(BuildInfo.commit) (\(BuildInfo.branch)) · built \(BuildInfo.builtAt)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("buildInfoLabel")
            }
        }
        .sheet(isPresented: $showPlayerSettings) {
            PlayerSettingsView(library: library)
        }
        .sheet(item: $editorLoadout, onDismiss: refresh) { loadout in
            LoadoutEditorView(library: library, existing: loadout)
        }
        .sheet(item: $detailItem, onDismiss: {
            // Promote the pending edit only after the detail sheet is fully
            // gone, keeping the dismiss-then-present pair in separate
            // transactions.
            if let loadout = pendingEditLoadout {
                pendingEditLoadout = nil
                editorLoadout = loadout
            }
        }) { item in
            PlayableDetailView(item: item, library: library,
                               onPlay: { play($0, mode: $1) },
                               onEdit: { pendingEditLoadout = $0 },
                               onChanged: refresh)
        }
        .confirmationDialog(actionItem?.title ?? "", isPresented: actionDialogBinding,
                            titleVisibility: .visible, presenting: actionItem) { item in
            Button("Continue") { play(item, mode: .continueNewest) }
                .accessibilityIdentifier("continueAction")
            Button("New Game") { play(item, mode: .newGame) }
                .accessibilityIdentifier("newGameAction")
            Button("Details") { detailItem = item }
                .accessibilityIdentifier("detailsAction")
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
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in refresh() }
    }

    // Split out of `body`: a toolbar this size inline was enough for the Swift
    // type checker to give up entirely ("failed to produce diagnostic for
    // expression") rather than report a real error.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                showPlayerSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            // Identifier kept from the gear *menu* this button replaces: it is
            // the same door in the same place, and `ShipUITests` addresses it
            // by this name on its way to About.
            .accessibilityIdentifier("touchSchemeMenu")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            NavigationLink {
                LibraryView(library: library, importer: importer,
                            onPlay: { play($0, mode: $1) })
            } label: {
                Label("Manage", systemImage: "tray.full")
            }
            .accessibilityIdentifier("manageButton")
        }
    }

    private var actionDialogBinding: Binding<Bool> {
        Binding(get: { actionItem != nil }, set: { if !$0 { actionItem = nil } })
    }

    /// The Continue hero: full-width art, title, and when it was last played.
    /// One tap resumes its newest save.
    private func hero(for item: PlayableItem) -> some View {
        Button {
            play(item, mode: .continueNewest)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                TitleArtView(item: item, library: library)
                Text(item.title).font(.title2.bold())
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text("Continue")
                    if let played = item.lastPlayed {
                        Text("·")
                        Text(played, format: .relative(presentation: .named))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("continueHero")
    }

    private func tile(for item: PlayableItem) -> some View {
        Button {
            switch Shelf.tapAction(for: item, hasResumableSave: hasResumableSave) {
            case .actionSheet: actionItem = item
            case .launchNewGame: play(item, mode: .newGame)
            }
        } label: {
            PlayableTileView(item: item, library: library)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID(for: item))
        .contextMenu {
            if hasResumableSave(item) {
                Button("Continue") { play(item, mode: .continueNewest) }
            }
            Button("New Game") { play(item, mode: .newGame) }
            Button("Details") { detailItem = item }
            if case .preset(let loadout) = item {
                Button("Edit") { editorLoadout = loadout }
            }
            Button("Remove from Shelf", role: .destructive) {
                try? library.hide(item)
                refresh()
            }
        }
    }

    private func hasResumableSave(_ item: PlayableItem) -> Bool {
        PlayableLauncher.continuableSlot(for: item, library: library) != nil
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

    private func play(_ item: PlayableItem, mode: LaunchMode = .newGame) {
        lastExitCode = nil
        do {
            let plan = try PlayableLauncher.prepare(item, library: library, mode: mode)
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
        let all = (try? library.shelfItems()) ?? []
        items = Shelf.ordered(all)
        heroItem = Shelf.hero(from: all, hasResumableSave: hasResumableSave)
    }
}
