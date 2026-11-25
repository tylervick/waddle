import GameController
import SwiftUI
import UIKit

/// The home screen (spec §§2–3): a Continue hero, one adaptive grid of every
/// playable item, and two doors — a gear for player settings and Add for the
/// importer; files and hidden games live under Settings (spec §3.3). Replaces
/// the Play/Library `TabView`; management is reachable but never on the
/// primary path.
///
/// Composition is decided entirely by `LibraryService.shelfGames()` and the
/// pure functions in `Shelf`, which is what the hermetic tests exercise.
struct ShelfView: View {
    let library: LibraryService
    let importer: ImportService
    @Binding var lastExitCode: Int32?
    /// Where Details and Settings open on a regular-width window (issue
    /// #372). The inspector itself is `ContentView`'s; this view decides
    /// what goes in it and lends it `play` and `refresh`.
    let panelModel: ShelfPanelModel

    @State private var items: [Game] = []
    /// What the top zone shows: the welcome card, a Continue hero, or nothing.
    /// `Shelf.heroZone` decides; this only holds the answer.
    @State private var zone: Shelf.HeroZone = .empty
    /// `zone` as drawn: without the Continue hero while the launcher is in
    /// two halves, where the lower half is that game's page (issue #429).
    /// From the pose alone, so bending the device measures nothing.
    private var shownZone: Shelf.HeroZone {
        Shelf.heroZone(zone, inTwoHalves: panelModel.isSplit)
    }
    @State private var showImporter = false
    @State private var showLinkImport = false
    /// The item whose tap opened the Continue / New Game / Details sheet.
    @State private var actionItem: Game?
    /// Where that item is drawn: its tile, or the hero when the hero is its
    /// game. The dialog is anchored here (`actionDialogAnchor`).
    @State private var actionAnchor: ShelfActionAnchor?
    /// Which move of the anchor the pending relayout answers; a later move
    /// supersedes it (`relayActionDialogOnceSettled`).
    @State private var actionRelayGeneration = 0

    /// The game whose page is pushed (spec §3.2): one screen for every tile,
    /// reached by navigation rather than a sheet.
    @State private var pageGame: Game?
    /// The non-base game a destructive context-menu tap is confirming removal
    /// of, via `deleteGamePrompt`.
    @State private var deleteCandidate: Game?
    @State private var showPlayerSettings = false
    @AppStorage(debugHUDUserDefaultsKey) private var debugHUD: Bool = false
    @State private var errorAlert: EngineErrorAlert?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Compact is a landscape phone and nothing else (design-system spec §9):
    /// the one height class where the hero zone goes side by side.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var compactHeight: Bool { verticalSizeClass == .compact }

    /// Width available to the hero's art and the height visible without
    /// scrolling, measured from the scroll view itself rather than from its
    /// contents: the contents are as tall as they need to be, and it is the
    /// *viewport* the hero has to fit inside (`ShelfHeroLayout`). Both start
    /// at zero, which that type reads as "not measured yet".
    @State private var heroContentWidth: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    /// What the wider of the hero's two button labels needs on one line, as
    /// SwiftUI lays it out at the reader's text size (`heroButtonLabelGauge`).
    /// Zero until measured, which asks nothing of the art.
    @State private var heroButtonLabelWidth: CGFloat = 0
    /// The taller of the two labels, from the same gauge: a `Label`'s icon
    /// makes it a little taller than its text's line (issue #457).
    @State private var heroButtonLabelHeight: CGFloat = 0

    /// Adaptive, and re-derived from the current Dynamic Type size rather than
    /// fixed: at accessibility sizes the wider floor fits fewer columns, which
    /// is spec §5's "drops columns rather than shrinking text".
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: tileMinimumWidth), spacing: gridSpacing)]
    }

    /// The grid's tile floor for the width the shelf has been measured at:
    /// the phone floor until that is known and on anything phone-sized, a
    /// wider one on a wide window (issue #353). One property, because the
    /// column definition and the hero zone's budget must agree on it.
    private var tileMinimumWidth: CGFloat {
        Theme.gridMinimumTileWidth(for: dynamicTypeSize, contentWidth: heroContentWidth)
    }

    /// The shape of a grid tile in this window: 4:3, or wider where a tile of
    /// that shape would be taller than the viewport (issue #431).
    ///
    /// Worked out, not measured: the column's width is the arithmetic
    /// `ShelfHeroLayout.gridColumnWidth` already does for the hero's budget,
    /// over the scroll view's own width and height. Neither of those follows
    /// the shelf's content (issue #437), and a tile's own frame is never read.
    private var tileAspectRatio: CGFloat {
        PlayableTileLayout.tileAspectRatio(
            width: ShelfHeroLayout.gridColumnWidth(contentWidth: heroContentWidth,
                                                   minimum: tileMinimumWidth,
                                                   spacing: gridSpacing),
            viewportHeight: viewportHeight,
            contentPadding: contentPadding)
    }

    var body: some View {
        // The content is laid out at, and reports, the width the scroll view
        // is offered and nothing else. The scroll view is measured below to
        // size the hero, and a scroll view follows content that reports
        // wider than offered: without this the measurement fed itself and a
        // launch could spin for ever (issue #437). Not the scroll view's own
        // width either: that follows the content too, and a column opening
        // beside the shelf left it wider than its column and cut (issue #469).
        OfferedWidthScrollView {
            ScrollViewReader { scroller in
                VStack(alignment: .leading,
                       spacing: ShelfHeroLayout.sectionSpacing(compactHeight: compactHeight)) {
                    switch shownZone {
                    case .welcome: welcomeCard
                    case .resume(let game): hero(for: game).id(game.id)
                    case .empty: EmptyView()
                    }
                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        // Not `items`: the hero's game would otherwise repeat as
                        // the first tile directly beneath itself. `Shelf.gridItems`
                        // owns that rule and is where it is tested.
                        ForEach(Shelf.gridItems(from: items, heroZone: shownZone)) { item in
                            tile(for: item).id(item.id)
                        }
                        if Shelf.showsAddHint(itemCount: items.count) {
                            addHintTile
                        }
                    }
                }
                .padding(contentPadding)
                // A turn, a resized window or a change of pose can leave the
                // game whose actions are up out of view: landscape's shorter
                // window, or a tile low in a scrolled shelf whose columns
                // changed. It is brought back the least distance, so the
                // actions keep pointing at something on screen.
                .onChange(of: heroContentWidth) { revealActionItem(scroller) }
                .onChange(of: viewportHeight) { revealActionItem(scroller) }
                .onChange(of: panelModel.isSplit) { revealActionItem(scroller) }
            }
        }
        // A tile's actions are presented from here, above the lazy grid, and
        // only their anchor follows the tile. From iOS 26 a confirmation
        // dialog on an iPhone is a popover anchored to the view carrying it:
        // on the shelf's root, every tile's actions pointed at the screen's
        // middle (issue #532); on the tile itself, they went with the tile
        // when the grid rebuilt it for a turn of the phone, and when the
        // hero took its game back on opening a Duo flat (review of pull
        // request 536). Here the dialog lives as long as the shelf does and
        // points at whatever draws the game now.
        .coordinateSpace(.named(Self.actionAnchorSpace))
        .overlay(alignment: .topLeading) { actionDialogAnchor }
        // Measured round the ScrollView, at what it is offered, so this is the
        // viewport: what is visible between the toolbar and the home
        // indicator, less the padding above.
        // Rotation and window resizing both re-fire it.
        //
        // `proxy.size` is already that region -- 724 pt on an iPhone 17 Pro --
        // with the bars outside it reported separately as `safeAreaInsets`.
        // Subtracting those again (as this did until 2026-09-30) under-measured
        // the viewport by 150 pt, so the hero zone's budget was spent against
        // a screen 20% shorter than the one it was drawn on. See
        // `docs/learnings/geometry-proxy-size-already-excludes-safe-area.md`.
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: proxy.size.width - contentPadding * 2,
                   height: proxy.size.height)
        } action: { size in
            heroContentWidth = size.width
            viewportHeight = size.height
        }
        .background(Color.appBackground)
        // The title stays set — it is the back button's label on the game
        // page and what `navigationBars["Waddle"]` matches — but what the bar
        // *shows* is the wordmark (design-system spec §5): the one retro
        // element in the shell, and the thing that ties it to the icon.
        .navigationTitle("Waddle")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        // Pushed, not presented (spec §3.2): one page for every tile, and no
        // second sheet to promote after the first dismisses.
        .navigationDestination(item: $pageGame) { game in
            // The page's presentation state is the panel model's, so a
            // page that moves to the lower half when the device is bent
            // takes its open dialog with it (issue #429).
            GamePageView(game: game, library: library,
                         onPlay: { play($0, mode: $1) },
                         onChanged: refresh,
                         onClose: { pageGame = nil },
                         presentation: panelModel.gamePagePresentation(for: game))
                .environment(\.panelHost, panelModel.columnHost)
                .onDisappear { if pageGame == nil { panelModel.pageClosed(game) } }
        }
        .deleteGamePrompt(game: $deleteCandidate, library: library, onDeleted: refresh)
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
        // `onDismiss: refresh`, not just `.onAppear` on this view: Settings is
        // a sheet, so dismissing it never re-runs the presenter's `onAppear`.
        // Files and Hidden Games live under Settings and can restore or
        // delete WADs, and without this the shelf would keep showing stale
        // tiles until some other trigger happened to call `refresh()`.
        .sheet(isPresented: $showPlayerSettings, onDismiss: {
            panelModel.settingsSheetClosed()
            refresh()
        }) {
            PlayerSettingsView(library: library, presentation: panelModel.settingsPresentation)
                .environment(\.panelHost, panelModel.columnHost)
        }
        // The panel's content is built at the root, but starting a session
        // and reloading the shelf are this view's. Closing the panel
        // refreshes for the same reason dismissing the Settings sheet does:
        // Files and Hidden Games under it can change what the shelf shows.
        .onAppear {
            panelModel.play = { play($0, mode: $1) }
            panelModel.changed = { refresh() }
        }
        .onChange(of: panelModel.panel) { _, panel in
            if panel == nil { refresh() }
        }
        // Bent with a page pushed or the Settings sheet up, which is how a
        // compact window has them (a closed iPhone Duo opened straight to
        // half open): each moves to the lower half, where it would have
        // opened in this pose. Left alone, the page would take the shelf's
        // half and the sheet would lie across the fold (issue #429).
        .onChange(of: panelModel.isSplit) { _, isSplit in
            guard isSplit else { return }
            // The panel is set before the sheet or the page goes, so that
            // when it has gone its state is seen to have moved, not closed.
            if showPlayerSettings {
                panelModel.panel = .settings
                showPlayerSettings = false
            } else if let game = pageGame {
                panelModel.panel = .game(game)
                pageGame = nil
            }
        }
        #if DEBUG
        // Test-only seam, same WADDLE_* family as the others: opens the
        // panel at launch so a capture can show it without a gesture. On an
        // open iPhone Duo nothing synthetic can long-press a tile to reach
        // Details (`docs/learnings/iphone-duo-simulator-traps.md`).
        // `settings`, or a game's name. Never set in production.
        .task {
            guard let wanted = ProcessInfo.processInfo.environment["WADDLE_OPEN_PANEL"] else { return }
            try? await Task.sleep(for: .milliseconds(800))
            guard panelModel.opensInPanel else { return }
            if wanted == "settings" {
                panelModel.panel = .settings
            } else if let game = items.first(where: { $0.name == wanted }) {
                panelModel.panel = .game(game)
            }
        }
        #endif
        // The welcome card's Add Your Games opens the same importer the
        // toolbar's Add button and the ghost tile do, down to the accepted
        // types (spec §4).
        .wadFileImporter(isPresented: $showImporter, importer: importer) { _ in
            refresh()
        }
        .sheet(isPresented: $showLinkImport) {
            LinkImportSheet(importer: importer)
        }
        .alert(errorAlert?.title ?? "", isPresented: Binding(
            get: { errorAlert != nil }, set: { if !$0 { dismissErrorAlert() } }
        ), presenting: errorAlert) { _ in
            Button("OK") { dismissErrorAlert() }
        } message: { alert in
            Text([alert.engineMessage, alert.hint].compactMap { $0 }
                .joined(separator: "\n\n"))
        }
        .onAppear {
            refresh()
            #if DEBUG || WADDLE_PROFILE_HARNESS
            startProfileSessionIfRequested()
            #endif
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidChange)) { _ in refresh() }
    }

    // Split out of `body`: a toolbar this size inline was enough for the Swift
    // type checker to give up entirely ("failed to produce diagnostic for
    // expression") rather than report a real error.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // No interpolation: a 15 px pixel face at `Theme.wordmarkHeight`
            // is an integer number of device pixels per source pixel, and
            // smoothing it is what turns a crisp bevel into mush.
            Image("WaddleWordmark")
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(height: Theme.wordmarkHeight)
                .accessibilityLabel("Waddle")
                .accessibilityAddTraits(.isHeader)
        }
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                openSettings()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            // Identifier kept from the gear *menu* this button replaces: it is
            // the same door in the same place, and `ShipUITests` addresses it
            // by this name on its way to About.
            .accessibilityIdentifier("touchSchemeMenu")
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            // The one import door (spec §3.4): From Files… opens the same
            // importer the welcome card and the ghost tile do; From a Link…
            // is the only way in that downloads (#500).
            Menu {
                Button {
                    showImporter = true
                } label: {
                    Label("From Files…", systemImage: "folder")
                }
                .accessibilityIdentifier("importFromFiles")
                Button {
                    showLinkImport = true
                } label: {
                    Label("From a Link…", systemImage: "link")
                }
                .accessibilityIdentifier("importFromLink")
            } label: {
                Label("Add", systemImage: "plus")
            }
            .accessibilityIdentifier("importButton")
        }
    }

    /// A game's page: beside the library on a regular-width window, pushed
    /// on a compact one (issue #372). What a tap on a tile does is the same
    /// everywhere; this is only where Details lands.
    private func openDetails(_ game: Game) {
        if panelModel.opensInPanel {
            panelModel.panel = .game(game)
        } else {
            pageGame = game
        }
    }

    /// Settings: the same panel on a regular-width window, the sheet on a
    /// compact one.
    private func openSettings() {
        if panelModel.opensInPanel {
            panelModel.panel = .settings
        } else {
            showPlayerSettings = true
        }
    }

    /// Up once the item's anchor has been measured, so the popover never
    /// opens pointing at the last game's.
    private var actionDialogShown: Binding<Bool> {
        Binding(get: { actionItem != nil && actionAnchor?.id == actionItem?.id },
                set: { if !$0 { actionItem = nil } })
    }

    static let actionAnchorSpace = "shelfActionAnchor"

    /// A clear view over whatever draws the game whose actions are up,
    /// carrying the dialog. It is not in the grid, so nothing the grid does
    /// to its tiles takes the dialog down; when the tile leaves the screen
    /// it stays where the tile was last seen until the tile is back.
    private var actionDialogAnchor: some View {
        let rect = actionAnchor?.rect ?? .zero
        return Color.clear
            .frame(width: max(rect.width, 1), height: max(rect.height, 1))
            .confirmationDialog(actionItem?.name ?? "", isPresented: actionDialogShown,
                                titleVisibility: .visible, presenting: actionItem) { item in
                Button("Continue") { play(item, mode: .continueNewest) }
                    .accessibilityIdentifier("continueAction")
                Button("New Game") { play(item, mode: .newGame) }
                    .accessibilityIdentifier("newGameAction")
                Button("Details") { openDetails(item) }
                    .accessibilityIdentifier("detailsAction")
            }
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Put behind the view that draws `game` (its tile, or the hero): while
    /// `game`'s actions are up, it reports where that view is, which is all
    /// the dialog's anchor follows.
    @ViewBuilder
    private func actionAnchorReporter(for game: Game) -> some View {
        if actionItem?.id == game.id {
            Color.clear.onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named(Self.actionAnchorSpace))
            } action: { rect in
                let moved = actionAnchor?.id == game.id && actionAnchor?.rect != rect
                actionAnchor = ShelfActionAnchor(id: game.id, rect: rect)
                if moved { relayActionDialogOnceSettled() }
            }
        }
    }

    /// Lays the actions' popover out afresh once its anchor has stopped
    /// moving. SwiftUI keeps the popover's source rect on the anchor as it
    /// moves, but UIKit places a popover only when it is presented and when
    /// its container lays out, which a change of window size causes and a
    /// move within an unchanged window does not. So after a Duo's change of
    /// pose, where the hero comes back over the tile's place, the popover
    /// stayed where the tile had put it: pointing into the hero on an
    /// iPhone 18 Pro, 30 pt below it on an iPhone Duo, which is the device
    /// this pose belongs to (re-review of pull request 536). Re-presenting
    /// the dialog was tried and left the popover at the hero's place after
    /// bending again; laying out its container is what moved it, every time.
    private func relayActionDialogOnceSettled() {
        actionRelayGeneration += 1
        let generation = actionRelayGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard generation == actionRelayGeneration, actionItem != nil else { return }
            ShelfActionPopover.layOutAgain()
        }
    }

    private func revealActionItem(_ scroller: ScrollViewProxy) {
        guard let id = actionItem?.id else { return }
        scroller.scrollTo(id)
    }

    /// The inset around the whole shelf. Named because the hero's own width is
    /// derived from it above, and a `.padding()` that means one thing to the
    /// layout and another to the measurement would cap the hero against a
    /// width it is not drawn at.
    private var contentPadding: CGFloat { 16 }

    /// Grid gap, shared by the column definition and the row spacing below, so
    /// the width `ShelfHeroLayout` reasons about is the width actually drawn.
    ///
    /// 20, deliberately off the outer padding's 16: with every interval equal
    /// the screen has no rhythm, and between two edge-to-edge art tiles a
    /// 16 pt gap disappears entirely (2026-08-21 design pass). Two columns
    /// still fit the narrowest supported phone — the 360 pt mini gives
    /// (328 − 20) / 2 = 154 pt tiles against the 150 pt floor, and
    /// `ShelfHeroLayoutTests` pins that arithmetic off its boundary.
    private var gridSpacing: CGFloat { 20 }

    /// Whether the welcome card can afford its description line on this
    /// viewport (spec §4 vs. the shelf staying playable in one tap).
    ///
    /// The heights come from `UIFont` rather than from constants, the same
    /// way `heroCaptionHeight` below does: every row of the card grows at
    /// accessibility text sizes, and so does the tile row it has to leave room
    /// for, so a budget written against the default size would clear a card
    /// that does not fit.
    private var showsWelcomeDescription: Bool {
        ShelfHeroLayout.welcomeCardShowsDescription(
            viewportHeight: viewportHeight,
            contentWidth: heroContentWidth,
            tileMinimumWidth: tileMinimumWidth,
            contentPadding: contentPadding,
            gridSpacing: gridSpacing,
            fullCardHeight: ShelfHeroLayout.welcomeCardHeight(
                descriptionHeight: welcomeDescriptionHeight,
                buttonHeight: welcomeButtonHeight,
                compactHeight: compactHeight),
            compactHeight: compactHeight)
    }

    /// `WaddlePrimaryButtonStyle` with its `minHeight`, so the row is the
    /// taller of that floor and the label's own line box plus the style's
    /// vertical padding.
    private var welcomeButtonHeight: CGFloat {
        max(Theme.minimumTapTarget,
            UIFont.preferredFont(forTextStyle: .body).lineHeight
                + Theme.buttonVerticalPadding * 2)
    }

    /// The description as it actually wraps at this width and text size —
    /// two lines by default, more at accessibility sizes, which is the whole
    /// reason this is measured instead of assumed.
    private var welcomeDescriptionHeight: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        var inner = heroContentWidth - ShelfHeroLayout.welcomeCardPadding * 2
        // Beside the button the tagline has half the card, less the gap.
        if compactHeight { inner = (inner - ShelfHeroLayout.welcomeCardRowSpacing) / 2 }
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
    private var heroCaptionSpacing: CGFloat { ShelfHeroLayout.captionSpacing }

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
        // No app-name row (spec §4, amended 2026-08-21): the navigation title
        // directly above this card already says "Waddle", and a first launch
        // was greeting the player with the name twice in a row.
        // Tagline over button, or beside it on a landscape phone (design-system
        // spec §9), where a stacked card would push the first tile row off the
        // fold before the tagline had earned its place.
        Group {
            switch ShelfHeroLayout.arrangement(compactHeight: compactHeight) {
            case .stacked:
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    welcomeDescriptionText
                    welcomeButton
                }
            case .sideBySide:
                HStack(alignment: .center, spacing: Theme.Spacing.md) {
                    welcomeDescriptionText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    welcomeButton
                        .frame(maxWidth: .infinity)
                }
            }
        }
        // `waddleCard` pads by `Theme.Spacing.base`, which is
        // `ShelfHeroLayout.welcomeCardPadding` -- the measured card height
        // depends on the two agreeing.
        .waddleCard()
        .accessibilityIdentifier("welcomeCard")
    }

    /// Dropped on viewports where the card would otherwise push the first
    /// tile row past the fold -- see
    /// `ShelfHeroLayout.welcomeCardShowsDescription`. The button is what spec
    /// §4 leads with; the sentence is the part that can go when "playable in
    /// one tap" is the thing at stake.
    @ViewBuilder
    private var welcomeDescriptionText: some View {
        if showsWelcomeDescription {
            Text(Self.welcomeDescription)
                .font(Theme.Typography.secondary)
                .foregroundStyle(Color.appSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Adding games is this screen's primary action while it is on screen,
    /// and spec §5 names it as one of the two that wear the single accent
    /// (the other being Continue, which by §4's rule cannot be showing at the
    /// same time). The primary style owns the dark label the light accent
    /// needs.
    private var welcomeButton: some View {
        Button("Add Your Games") {
            showImporter = true
        }
        .buttonStyle(.waddlePrimary)
        .accessibilityIdentifier("addYourGamesButton")
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
    private func hero(for game: Game) -> some View {
        Group {
            switch heroArrangement {
            case .stacked:
                // One button, art over caption: a tap anywhere resumes.
                Button {
                    play(game, mode: .continueNewest)
                } label: {
                    VStack(alignment: .leading, spacing: heroCaptionSpacing) {
                        heroArt(game, height: stackedHeroArtHeight)
                        heroCaption(game)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("continueHero")
                .accessibilityLabel("Continue \(TileAccessibility.label(for: game))")
            case .sideBySide:
                // Art beside its caption: a landscape phone (design-system
                // spec §9), where stacked art was on its 96 pt floor, and a
                // wide window, where it was a banner it could not fill
                // (issue #371). The row beside the art has room for the two
                // actions as buttons, so they are buttons.
                HStack(alignment: .top, spacing: ShelfHeroLayout.sideBySideSpacing) {
                    Button {
                        play(game, mode: .continueNewest)
                    } label: {
                        heroArt(game, height: ShelfHeroLayout.sideBySideArtHeight(
                            contentWidth: heroContentWidth, viewportHeight: viewportHeight,
                            captionMinimumWidth: heroButtonMinimumWidth))
                            .frame(width: ShelfHeroLayout.sideBySideArtWidth(
                                contentWidth: heroContentWidth, viewportHeight: viewportHeight,
                                captionMinimumWidth: heroButtonMinimumWidth))
                    }
                    .buttonStyle(.plain)
                    // The art is a second, larger target for the Continue
                    // button beside it. VoiceOver gets the button, not both.
                    .accessibilityHidden(true)
                    sideBySideHeroCaption(game)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background { heroButtonLabelGauge }
            }
        }
        .contextMenu { contextMenuItems(for: game) }
        // Opening a Duo flat brings the hero back and takes its game's tile
        // out of the grid; the game's actions move here with it.
        .background { actionAnchorReporter(for: game) }
    }

    /// Where the hero puts its art for the window it is in. `ShelfHeroLayout`
    /// owns the rule and is where it is tested.
    private var heroArrangement: ShelfHeroLayout.Arrangement {
        ShelfHeroLayout.arrangement(compactHeight: compactHeight,
                                    contentWidth: heroContentWidth,
                                    stackedArtHeight: stackedHeroArtHeight)
    }

    /// The art's height when it sits over its caption, capped against the
    /// viewport so the first tile row stays above the fold.
    private var stackedHeroArtHeight: CGFloat {
        ShelfHeroLayout.artHeight(
            contentWidth: heroContentWidth,
            viewportHeight: viewportHeight,
            captionHeight: heroCaptionHeight,
            gridPeek: ShelfHeroLayout.gridPeek(
                contentWidth: heroContentWidth,
                tileMinimumWidth: tileMinimumWidth,
                gridSpacing: gridSpacing,
                contentPadding: contentPadding,
                viewportHeight: viewportHeight))
    }

    /// The caption beside the art: title, when it was last played, and the
    /// two things to do with it. The same buttons, in the same styles, as the
    /// game page's (design-system spec §3): Continue is the primary action
    /// and wears the accent, New Game sits next to it.
    private func sideBySideHeroCaption(_ game: Game) -> some View {
        let captionWidth = ShelfHeroLayout.sideBySideCaptionWidth(
            contentWidth: heroContentWidth, viewportHeight: viewportHeight,
            captionMinimumWidth: heroButtonMinimumWidth)
        let lastPlayed = game.lastPlayed.map(HeroSideBySideCaption.lastPlayedText)
        let category = UIContentSizeCategory(dynamicTypeSize)
        // The last-played line gives way where it would push Continue below
        // the viewport (issue #457). Arithmetic over the reader's fonts at
        // the caption's width, never a frame of the caption's own.
        let showsLastPlayed = lastPlayed.map { text in
            ShelfHeroLayout.sideBySideCaptionShowsLastPlayed(
                viewportHeight: viewportHeight,
                contentPadding: contentPadding,
                titleHeight: HeroSideBySideCaption.titleHeight(game.name, width: captionWidth,
                                                               category: category),
                lastPlayedHeight: HeroSideBySideCaption.lastPlayedHeight(text, width: captionWidth,
                                                                         category: category),
                buttonHeight: HeroSideBySideCaption.buttonHeight(labelHeight: heroButtonLabelHeight))
        } ?? false
        return HeroSideBySideCaption(
            title: game.name,
            lastPlayed: showsLastPlayed ? lastPlayed : nil,
            // In a row where the caption holds two buttons as wide as the
            // wider label, stacked where it does not. `ShelfHeroLayout`
            // owns the rule and is where it is tested; `ViewThatFits` asked
            // a different question and let through rows that cut "New Game".
            buttonArrangement: ShelfHeroLayout.buttonArrangement(
                captionWidth: captionWidth, buttonMinimumWidth: heroButtonMinimumWidth),
            buttonsDisabled: game.baseID == nil,
            continueAccessibilityLabel: "Continue \(TileAccessibility.label(for: game))",
            onContinue: { play(game, mode: .continueNewest) },
            onNewGame: { play(game, mode: .newGame) })
    }

    /// The narrowest caption column that shows either button's label whole:
    /// the wider label plus the button style's padding either side of it.
    /// `ShelfHeroLayout.sideBySideArtHeight` takes it out of the art's half.
    private var heroButtonMinimumWidth: CGFloat {
        heroButtonLabelWidth > 0 ? heroButtonLabelWidth + Theme.Spacing.base * 2 : 0
    }

    /// The two labels at their natural width, never drawn: measured from the
    /// views themselves rather than from `UIFont`, because a `Label`'s icon
    /// and the gap after it are SwiftUI's to size and both grow with the text.
    /// At the largest accessibility size a label is wider than half the row
    /// of an open iPhone Duo turned tall, and the buttons were cut to
    /// "Contin…" and "New Ga…" (issue #424).
    ///
    /// One over the other, so the gauge is as wide as the wider label and as
    /// tall as the taller. It is laid out on its own, at its ideal size, so
    /// nothing the hero draws can change what it reads.
    private var heroButtonLabelGauge: some View {
        ZStack {
            HeroSideBySideCaption.continueLabel
            HeroSideBySideCaption.newGameLabel
        }
        .font(Theme.Typography.button)
        .fixedSize()
        .hidden()
        .accessibilityHidden(true)
        .onGeometryChange(for: CGSize.self) { proxy in
            CGSize(width: ceil(proxy.size.width), height: ceil(proxy.size.height))
        } action: { size in
            heroButtonLabelWidth = size.width
            heroButtonLabelHeight = size.height
        }
    }

    private func heroArt(_ game: Game, height: CGFloat) -> some View {
        TitleArtView(game: game, library: library,
                     aspectRatio: Theme.heroAspectRatio,
                     height: height)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    /// The title over the Continue line. Continue is this screen's primary
    /// action, so it -- and only it -- wears the one accent (spec §5); the
    /// last-played half stays secondary.
    private func heroCaption(_ game: Game) -> some View {
        VStack(alignment: .leading, spacing: heroCaptionSpacing) {
            Text(game.name).font(Theme.Typography.heroTitle)
            // On one line where it fits, Continue over the date where it does
            // not. Squeezed into one row at the largest accessibility size on
            // a closed iPhone Duo, the two halves became columns and the
            // hero's own action was broken as "Con-" / "tinue" (issue #424).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.xs) {
                    heroCaptionAction
                    if let played = game.lastPlayed {
                        Text("·")
                        Text(played, format: .relative(presentation: .named))
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    heroCaptionAction
                    if let played = game.lastPlayed {
                        Text(played, format: .relative(presentation: .named))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .font(Theme.Typography.secondary)
            .foregroundStyle(Color.appSecondaryText)
        }
    }

    /// The word Continue and its glyph, in the accent. One line at its own
    /// width wherever it is put: this is the hero's action, and it is never
    /// the half that gives way.
    private var heroCaptionAction: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "play.fill")
            Text("Continue")
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(Color.appAccent)
    }

    /// The ghost tile closing a small library's grid (spec §5, amended
    /// 2026-08-21): the same slot, shape and radius as a real tile, drawn as
    /// an outline so it reads as an invitation rather than a game. Same
    /// action as **Add Your Games**; `Shelf.showsAddHint` decides when it
    /// appears at all.
    private var addHintTile: some View {
        Button {
            showImporter = true
        } label: {
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .strokeBorder(Color.appSecondaryText.opacity(0.35),
                              style: StrokeStyle(lineWidth: 1, dash: [6, 5]))
                .aspectRatio(tileAspectRatio, contentMode: .fit)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.title2)
                        Text("Add Games")
                            .font(.subheadline)
                    }
                    .foregroundStyle(Color.appSecondaryText)
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("addGamesHintTile")
        .accessibilityLabel("Add Games")
    }

    private func tile(for game: Game) -> some View {
        Button {
            switch Shelf.tapAction(for: game, hasResumableSave: hasResumableSave) {
            case .actionSheet: actionItem = game
            case .launchNewGame: play(game, mode: .newGame)
            case .openPage: openDetails(game)
            }
        } label: {
            PlayableTileView(game: game, library: library, aspectRatio: tileAspectRatio)
                // The tile whose page is open beside the library wears the
                // accent, so the panel reads as belonging to something.
                .overlay {
                    if panelModel.shownGameID == game.id {
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(Color.appAccent, lineWidth: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID(for: game))
        // Replaces the merged title-plus-scrim reading with spec §5's phrasing
        // ("DOOM II, last played yesterday"). Set here rather than inside
        // `PlayableTileView` on purpose: the label belongs to the button that
        // already owns this tile's identifier and traits, and making the tile
        // its own accessibility element would split the two apart.
        .accessibilityLabel(TileAccessibility.label(for: game))
        .contextMenu { contextMenuItems(for: game) }
        .background { actionAnchorReporter(for: game) }
    }

    /// One menu for every presentation of an item. The hero needs it too
    /// since spec §2's 2026-08-21 amendment: its game no longer repeats as a
    /// tile, so this menu is where that game's New Game, Details and Remove
    /// live — losing the tile must not lose the gestures.
    @ViewBuilder
    private func contextMenuItems(for game: Game) -> some View {
        if hasResumableSave(game) {
            Button("Continue") { play(game, mode: .continueNewest) }
                .disabled(game.baseID == nil)
        }
        Button("New Game") { play(game, mode: .newGame) }
            .disabled(game.baseID == nil)
        Button("Details") { openDetails(game) }
        if game.isBaseGame {
            Button("Hide from Shelf", role: .destructive) {
                try? library.hide(game)
                refresh()
            }
        } else {
            Button("Delete", role: .destructive) { deleteCandidate = game }
        }
    }

    private func hasResumableSave(_ game: Game) -> Bool {
        GameLauncher.continuableSlot(for: game, library: library) != nil
    }

    /// Identifiers the UI tests address tiles by. Kept byte-for-byte through
    /// the Game switch (plan 1); plan 2 renames them with the screens.
    private func accessibilityID(for game: Game) -> String {
        if game.isBaseGame && game.name == "Freedoom Phase 1" { return "playFreedoom1" }
        return "game-\(game.name)"
    }

    /// Starts the session on the main run loop's next pass instead of inside
    /// the tap that asked for it (issue #95). The engine runs synchronously
    /// until the session ends, so starting it from a button action nested the
    /// whole session inside UIKit's dispatch of that tap, and UIKit does not
    /// deliver another gesture's action until the first one returns. Touch
    /// input still arrived, but SDL's error box (`I_ErrorMsg`) highlighted OK
    /// and never ran its action, so the app needed a force quit.
    ///
    /// A run-loop block, not `DispatchQueue.main.async` or a `@MainActor`
    /// task: those would run the session inside a main-queue block, and the
    /// serial main queue would then hold every other block queued to it (the
    /// UI tests' autoquit, SwiftUI's own async work) until the session ended.
    private func play(_ game: Game, mode: LaunchMode = .newGame) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { startSession(game, mode: mode) }
        }
        CFRunLoopWakeUp(main)
    }

    #if DEBUG || WADDLE_PROFILE_HARNESS
    /// Profiling only (issue #246, see `ProfileHarness`): starts the game the
    /// launch environment names, once, without a tap, and ends the process
    /// when that session exits cleanly -- which is what stops
    /// `xctrace record --launch`, so a trace holds the demo and no idle
    /// launcher after it. A session that failed leaves the app, and its
    /// error alert, on screen instead.
    ///
    /// Matches the title exactly across the full library, including hidden
    /// games, preferring a base game. An invalid request, missing game, or
    /// library read error returns without starting a session. A match is
    /// scheduled on the main run loop and consumes this launch's one attempt,
    /// even if starting or running the session fails.
    private func startProfileSessionIfRequested() {
        guard !ProfileHarness.started,
              let request = ProfileHarness.request(
                  environment: ProcessInfo.processInfo.environment)
        else { return }
        let games = (try? library.games()) ?? []
        guard let game = games.first(where: { $0.isBaseGame && $0.name == request.gameName })
            ?? games.first(where: { $0.name == request.gameName })
        else { return }
        ProfileHarness.started = true
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                startSession(game, mode: .newGame)
                if lastExitCode == 0 { exit(0) }
            }
        }
        CFRunLoopWakeUp(main)
    }
    #endif

    private func startSession(_ game: Game, mode: LaunchMode) {
        lastExitCode = nil
        // Recorded before prepare() can throw: the user did try to start this
        // one, and a "session begin" with an immediate argument-failure end is
        // a truer trail than no begin at all.
        BreadcrumbLog.shared.record(.sessionBegin(name: game.name))
        // Counted here for the same reason, and on the main thread before the
        // engine starts: a session the engine never returns from (a crash)
        // then shows as started and never ended. The scheme is resolved the
        // way `GameLauncher.prepare` resolves it. The bucket, never the name:
        // see `UsageSummary`.
        var usageExitCode = EngineSession.ExitCode.argumentFailure
        let usage = UsageSession(
            store: .shared,
            bucket: UsageGameBucket.of(game, in: library),
            scheme: TouchControlScheme.effective(override: game.schemeOverrideRaw),
            controllerConnected: !GCController.controllers().isEmpty,
            orientation: Self.currentUsageOrientation(),
            startsActive: UIApplication.shared.applicationState == .active)
        defer { usage.end(exitCode: usageExitCode) }
        do {
            let plan = try GameLauncher.prepare(game, library: library, mode: mode)
            let exitCode = EngineSession.play(arguments: plan.arguments, scheme: plan.scheme)
            lastExitCode = exitCode
            usageExitCode = exitCode
            BreadcrumbLog.shared.record(
                .sessionEnd(exitCode: exitCode,
                            engineMessage: EngineSession.lastErrorMessage))
            present(EngineErrorAlert.from(exitCode: exitCode,
                                          engineMessage: EngineSession.lastErrorMessage))
        } catch {
            let message = LaunchFailure.message(for: error)
            lastExitCode = EngineSession.ExitCode.argumentFailure
            BreadcrumbLog.shared.record(
                .sessionEnd(exitCode: EngineSession.ExitCode.argumentFailure,
                            engineMessage: message))
            present(EngineErrorAlert.from(exitCode: EngineSession.ExitCode.argumentFailure,
                                          engineMessage: message))
        }
        refresh()
    }

    /// How the device is held right now, for the usage counts: the active
    /// window scene's interface orientation, portrait when it cannot be read.
    private static func currentUsageOrientation() -> UsageOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.effectiveGeometry.interfaceOrientation.isLandscape == true ? .landscape : .portrait
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
        let all = (try? library.shelfGames()) ?? []
        items = Shelf.ordered(all)
        // What the lower half shows with nothing open, while the launcher is
        // in two halves (issue #429).
        panelModel.restingGame = Shelf.restingGame(from: items)
        // A library that cannot be read is not a factory-state one: falling
        // back to `false` keeps a transient read failure from greeting a
        // player who has been here for months as a new arrival.
        zone = Shelf.heroZone(from: all,
                              isFactoryState: (try? library.isFactoryState()) ?? false,
                              hasResumableSave: hasResumableSave)
    }
}

/// The Continue hero's caption beside its art: the title, when it was last
/// played, and the Continue and New Game buttons (design-system spec §3).
///
/// Its own type so a test can draw it: the heights `ShelfView` hands
/// `ShelfHeroLayout.sideBySideCaptionShowsLastPlayed` are worked out from
/// the reader's fonts below, and `HeroCaptionFitTests` checks them against
/// this view as SwiftUI lays it out (issue #457).
struct HeroSideBySideCaption: View {
    let title: String
    /// Nil draws the caption without the line.
    let lastPlayed: String?
    let buttonArrangement: ShelfHeroLayout.ButtonArrangement
    var buttonsDisabled = false
    var continueAccessibilityLabel = "Continue"
    var onContinue: () -> Void = {}
    var onNewGame: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: ShelfHeroLayout.captionSpacing) {
            Text(title).font(Theme.Typography.heroTitle)
            if let lastPlayed {
                Text(lastPlayed)
                    .font(Theme.Typography.secondary)
                    .foregroundStyle(Color.appSecondaryText)
            }
            Group {
                switch buttonArrangement {
                case .row:
                    HStack(spacing: ShelfHeroLayout.buttonRowSpacing) { buttons }
                case .column:
                    VStack(spacing: Theme.Spacing.sm) { buttons }
                }
            }
            .padding(.top, ShelfHeroLayout.captionButtonsTopPadding)
        }
    }

    /// Continue and New Game, for whichever stack `buttonArrangement` chose.
    /// Labels stay on one line.
    @ViewBuilder
    private var buttons: some View {
        Button(action: onContinue) { Self.continueLabel }
            .buttonStyle(.waddlePrimary)
            .disabled(buttonsDisabled)
            .accessibilityIdentifier("continueHero")
            .accessibilityLabel(continueAccessibilityLabel)
        Button(action: onNewGame) { Self.newGameLabel }
            .buttonStyle(.waddleSecondary)
            .disabled(buttonsDisabled)
            .accessibilityIdentifier("heroNewGameButton")
    }

    static var continueLabel: some View {
        Label("Continue", systemImage: "clock.arrow.circlepath").lineLimit(1)
    }

    static var newGameLabel: some View {
        Label("New Game", systemImage: "play.fill").lineLimit(1)
    }

    /// One copy of the line's wording, because it is both drawn and measured.
    static func lastPlayedText(_ date: Date) -> String {
        "Last played \(date.formatted(.relative(presentation: .named)))"
    }

    // MARK: Heights, from the reader's fonts

    /// The title as it wraps at `width`.
    static func titleHeight(_ title: String, width: CGFloat, category: UIContentSizeCategory) -> CGFloat {
        let base = font(.title2, category)
        let bold = base.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: 0) } ?? base
        return wrappedHeight(title, font: bold, width: width)
    }

    /// The last-played line as it wraps at `width`.
    static func lastPlayedHeight(_ text: String, width: CGFloat, category: UIContentSizeCategory) -> CGFloat {
        wrappedHeight(text, font: font(.subheadline, category), width: width)
    }

    /// One button: its label and the style's vertical padding, never below
    /// the tap target (`WaddlePrimaryButtonStyle`). The label's height is
    /// measured from the label, as its width is: its icon makes it up to a
    /// point taller than `UIFont`'s line, and an estimate short of the drawn
    /// button would keep a line that pushes Continue out of sight.
    static func buttonHeight(labelHeight: CGFloat) -> CGFloat {
        max(Theme.minimumTapTarget, labelHeight + Theme.buttonVerticalPadding * 2)
    }

    private static func font(_ style: UIFont.TextStyle, _ category: UIContentSizeCategory) -> UIFont {
        UIFont.preferredFont(forTextStyle: style,
                             compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    private static func wrappedHeight(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard width > 0 else { return font.lineHeight }
        let box = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return ceil(box.height)
    }
}

/// Where the game whose actions are up is drawn, in the shelf's
/// `actionAnchorSpace`, and which game that is.
struct ShelfActionAnchor: Equatable {
    let id: UUID
    let rect: CGRect
}

/// The one popover a shelf shows over its grid: a tile's actions. While it
/// is up nothing else can be presented over the shelf, so the topmost
/// presented controller with a popover is it.
enum ShelfActionPopover {
    /// Asks UIKit to place the popover again against its current source
    /// rect, which SwiftUI keeps up to date (`relayActionDialogOnceSettled`).
    /// Measured on an iPhone Duo: the source rect already held the hero's
    /// frame after opening flat, and the tile's after bending again.
    @MainActor static func layOutAgain() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var top = window.rootViewController
                while let next = top?.presentedViewController { top = next }
                guard let popover = top?.popoverPresentationController,
                      let container = popover.containerView else { continue }
                // Its own value, set again: this marks the popover as
                // needing to be placed, which a layout alone may not.
                popover.sourceRect = popover.sourceRect
                container.setNeedsLayout()
                container.layoutIfNeeded()
            }
        }
    }
}
