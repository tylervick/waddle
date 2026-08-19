import SwiftUI
import UIKit

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
    /// What the top zone shows: the welcome card, a Continue hero, or nothing.
    /// `Shelf.heroZone` decides; this only holds the answer.
    @State private var zone: Shelf.HeroZone = .empty
    @State private var showImporter = false
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Width available to the hero's art and the height visible without
    /// scrolling, measured from the scroll view itself rather than from its
    /// contents: the contents are as tall as they need to be, and it is the
    /// *viewport* the hero has to fit inside (`ShelfHeroLayout`). Both start
    /// at zero, which that type reads as "not measured yet".
    @State private var heroContentWidth: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    /// Adaptive, and re-derived from the current Dynamic Type size rather than
    /// fixed: at accessibility sizes the wider floor fits fewer columns, which
    /// is spec §5's "drops columns rather than shrinking text".
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.gridMinimumTileWidth(for: dynamicTypeSize)),
                  spacing: gridSpacing)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ShelfHeroLayout.sectionSpacing) {
                switch zone {
                case .welcome: welcomeCard
                case .resume(let item): hero(for: item)
                case .empty: EmptyView()
                }
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    ForEach(items) { item in
                        tile(for: item)
                    }
                }
            }
            .padding(contentPadding)
        }
        // Measured on the ScrollView, so this is the viewport: its own frame,
        // less the insets the toolbar and home indicator occupy, less the
        // padding above. Rotation and window resizing both re-fire it.
        .onGeometryChange(for: CGSize.self) { proxy in
            let insets = proxy.safeAreaInsets
            return CGSize(
                width: proxy.size.width - insets.leading - insets.trailing - contentPadding * 2,
                height: proxy.size.height - insets.top - insets.bottom
            )
        } action: { size in
            heroContentWidth = size.width
            viewportHeight = size.height
        }
        .background(Color.appBackground)
        .navigationTitle("Waddle")
        .toolbar { toolbarContent }
        // .overlay, not .safeAreaInset -- a conditionally-empty safeAreaInset
        // directly above a ScrollView/LazyVGrid crashed SwiftUI's layout engine
        // here (HVGrid.minorGeometry, SwiftUI internal, iOS 26.2 SDK).
        .overlay(alignment: .bottom) {
            if debugHUD {
                Text("Waddle \(BuildInfo.commit) (\(BuildInfo.branch)) · built \(BuildInfo.builtAt)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.appSecondaryText)
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("buildInfoLabel")
            }
        }
        .sheet(isPresented: $showPlayerSettings) {
            PlayerSettingsView(library: library)
        }
        // The welcome card's Add Your Games opens the same importer Manage's
        // Import button does, down to the accepted types (spec §4).
        .wadFileImporter(isPresented: $showImporter, importer: importer) { _ in
            refresh()
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
            get: { errorAlert != nil }, set: { if !$0 { dismissErrorAlert() } }
        ), presenting: errorAlert) { _ in
            Button("OK") { dismissErrorAlert() }
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

    /// The inset around the whole shelf. Named because the hero's own width is
    /// derived from it above, and a `.padding()` that means one thing to the
    /// layout and another to the measurement would cap the hero against a
    /// width it is not drawn at.
    private var contentPadding: CGFloat { 16 }

    /// Grid gap, shared by the column definition and the row spacing below, so
    /// the width `ShelfHeroLayout` reasons about is the width actually drawn.
    private var gridSpacing: CGFloat { 16 }

    /// Whether the welcome card can afford its description line on this
    /// viewport (spec §4 vs. the shelf staying playable in one tap).
    ///
    /// The three heights come from `UIFont` rather than from constants, the
    /// same way `heroCaptionHeight` below does: every row of the card grows at
    /// accessibility text sizes, and so does the tile row it has to leave room
    /// for, so a budget written against the default size would clear a card
    /// that does not fit.
    private var showsWelcomeDescription: Bool {
        ShelfHeroLayout.welcomeCardShowsDescription(
            viewportHeight: viewportHeight,
            contentWidth: heroContentWidth,
            tileMinimumWidth: Theme.gridMinimumTileWidth(for: dynamicTypeSize),
            contentPadding: contentPadding,
            gridSpacing: gridSpacing,
            fullCardHeight: ShelfHeroLayout.welcomeCardHeight(
                titleHeight: welcomeTitleHeight,
                descriptionHeight: welcomeDescriptionHeight,
                buttonHeight: welcomeButtonHeight))
    }

    /// `.title` — the card's app-name row.
    private var welcomeTitleHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .title1).lineHeight
    }

    /// `.borderedProminent` with an explicit `minHeight`, so the row is the
    /// taller of that floor and the label's own line box plus the style's
    /// vertical padding.
    private var welcomeButtonHeight: CGFloat {
        max(Theme.minimumTapTarget,
            UIFont.preferredFont(forTextStyle: .body).lineHeight + 14)
    }

    /// The description as it actually wraps at this width and text size —
    /// two lines by default, more at accessibility sizes, which is the whole
    /// reason this is measured instead of assumed.
    private var welcomeDescriptionHeight: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let inner = heroContentWidth - ShelfHeroLayout.welcomeCardPadding * 2
        guard inner > 0 else { return font.lineHeight }
        let box = (Self.welcomeDescription as NSString).boundingRect(
            with: CGSize(width: inner, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil)
        return ceil(box.height)
    }

    /// One copy, because it is both rendered and measured.
    private static let welcomeDescription =
        "Bring your own WADs, or start with the Freedoom games below."

    /// Gap between the hero's art, title and Continue line.
    private var heroCaptionSpacing: CGFloat { 6 }

    /// What the hero's title and Continue line need below the art, measured
    /// rather than assumed: `UIFont` already carries the reader's Dynamic Type
    /// setting, so at accessibility sizes this reserves the taller block those
    /// two lines really occupy instead of a default-size constant that would
    /// leave the caption hanging off the bottom of a landscape phone -- the
    /// same reason `columns` re-derives its floor from `dynamicTypeSize`.
    private var heroCaptionHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .title2).lineHeight
            + UIFont.preferredFont(forTextStyle: .subheadline).lineHeight
            + heroCaptionSpacing * 2
    }

    /// The first-launch welcome card (spec §4): app name, one line, and the
    /// primary **Add Your Games** button. It sits in the hero zone because on a
    /// factory-state library there is no Continue hero to occupy it, and the
    /// Freedoom tiles stay on the shelf immediately below — the app is playable
    /// in one tap with nothing added, which is the property the card must not
    /// get in the way of.
    ///
    /// Deliberately not a `Button` wrapping the whole card: only the labelled
    /// control acts, so a reader dragging the shelf past it cannot start a file
    /// picker by accident.
    private var welcomeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waddle").font(.title.bold())
            // Dropped on viewports where the card would otherwise push the
            // first tile row past the fold -- see
            // `ShelfHeroLayout.welcomeCardShowsDescription`. The app name and
            // the button are what spec §4 leads with; the sentence is the part
            // that can go when "playable in one tap" is the thing at stake.
            if showsWelcomeDescription {
                Text(Self.welcomeDescription)
                    .font(.subheadline)
                    .foregroundStyle(Color.appSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                showImporter = true
            } label: {
                Text("Add Your Games")
                    .frame(maxWidth: .infinity, minHeight: Theme.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            // Adding games is this screen's primary action while it is on
            // screen, and spec §5 names it as one of the two that wear the
            // single accent (the other being Continue, which by §4's rule
            // cannot be showing at the same time).
            //
            // The label is forced black. The accent is a light green, and
            // borderedProminent's default white label measures 1.29:1 against
            // it -- a contrast failure. Black measures 16.32:1.
            .tint(Color.appAccent)
            .foregroundStyle(.black)
            .accessibilityIdentifier("addYourGamesButton")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface,
                    in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityIdentifier("welcomeCard")
    }

    /// The Continue hero: full-width art, title, and when it was last played.
    /// One tap resumes its newest save. It keeps the art's own wide shape
    /// rather than the 3:4 tile crop — spec §5 has the hero spanning the width.
    ///
    /// Its height, though, is capped against the viewport rather than left to
    /// the aspect ratio: at full width on a landscape phone that ratio asks
    /// for more height than the whole screen has, which used to push the grid
    /// — and this hero's own caption — below the fold. `ShelfHeroLayout` owns
    /// that arithmetic and is where it is tested.
    private func hero(for item: PlayableItem) -> some View {
        Button {
            play(item, mode: .continueNewest)
        } label: {
            VStack(alignment: .leading, spacing: heroCaptionSpacing) {
                TitleArtView(item: item, library: library,
                             aspectRatio: Theme.heroAspectRatio,
                             height: ShelfHeroLayout.artHeight(
                                contentWidth: heroContentWidth,
                                viewportHeight: viewportHeight,
                                captionHeight: heroCaptionHeight))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius,
                                                style: .continuous))
                Text(item.title).font(.title2.bold())
                HStack(spacing: 4) {
                    // Continue is this screen's primary action, so it — and
                    // only it — wears the one red accent (spec §5). The
                    // last-played half stays secondary.
                    Group {
                        Image(systemName: "play.fill")
                        Text("Continue")
                    }
                    .foregroundStyle(Color.appAccent)
                    if let played = item.lastPlayed {
                        Text("·")
                        Text(played, format: .relative(presentation: .named))
                    }
                }
                .font(.subheadline)
                .foregroundStyle(Color.appSecondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("continueHero")
        .accessibilityLabel("Continue \(TileAccessibility.label(for: item))")
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
        // Replaces the merged title-plus-scrim reading with spec §5's phrasing
        // ("DOOM II, last played yesterday"). Set here rather than inside
        // `PlayableTileView` on purpose: the label belongs to the button that
        // already owns this tile's identifier and traits, and making the tile
        // its own accessibility element would split the two apart.
        .accessibilityLabel(TileAccessibility.label(for: item))
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
        // Recorded before prepare() can throw: the user did try to start this
        // one, and a "session begin" with an immediate argument-failure end is
        // a truer trail than no begin at all.
        BreadcrumbLog.shared.record(.sessionBegin(name: item.title))
        do {
            let plan = try PlayableLauncher.prepare(item, library: library, mode: mode)
            let exitCode = EngineSession.play(arguments: plan.arguments, scheme: plan.scheme)
            lastExitCode = exitCode
            BreadcrumbLog.shared.record(
                .sessionEnd(exitCode: exitCode,
                            engineMessage: EngineSession.lastErrorMessage))
            present(EngineErrorAlert.from(exitCode: exitCode,
                                          engineMessage: EngineSession.lastErrorMessage))
        } catch {
            let message = "A file in this preset is missing from the library."
            lastExitCode = EngineSession.ExitCode.argumentFailure
            BreadcrumbLog.shared.record(
                .sessionEnd(exitCode: EngineSession.ExitCode.argumentFailure,
                            engineMessage: message))
            present(EngineErrorAlert.from(exitCode: EngineSession.ExitCode.argumentFailure,
                                          engineMessage: message))
        }
        refresh()
    }

    /// Both alert transitions go through these two, so every "alert presented"
    /// in the breadcrumb trail has a matching "alert dismissed" -- and the
    /// absence of that pairing is exactly the stuck-UI evidence a force quit
    /// otherwise destroys.
    private func present(_ alert: EngineErrorAlert?) {
        guard let alert else { return }
        errorAlert = alert
        BreadcrumbLog.shared.record(.alertPresented(title: alert.title))
    }

    /// Idempotent on purpose: the OK button and the alert's own dismissal
    /// binding both fire for one dismissal, and a second "alert dismissed"
    /// line would read as a second alert.
    private func dismissErrorAlert() {
        guard errorAlert != nil else { return }
        errorAlert = nil
        BreadcrumbLog.shared.record(.alertDismissed)
    }

    private func refresh() {
        let all = (try? library.shelfItems()) ?? []
        items = Shelf.ordered(all)
        // A library that cannot be read is not a factory-state one: falling
        // back to `false` keeps a transient read failure from greeting a
        // player who has been here for months as a new arrival.
        zone = Shelf.heroZone(from: all,
                              isFactoryState: (try? library.isFactoryState()) ?? false,
                              hasResumableSave: hasResumableSave)
    }
}
