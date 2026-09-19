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

    @State private var items: [Game] = []
    /// What the top zone shows: the welcome card, a Continue hero, or nothing.
    /// `Shelf.heroZone` decides; this only holds the answer.
    @State private var zone: Shelf.HeroZone = .empty
    @State private var showImporter = false
    /// The item whose tap opened the Continue / New Game / Details sheet.
    @State private var actionItem: Game?

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
                case .resume(let game): hero(for: game)
                case .empty: EmptyView()
                }
                LazyVGrid(columns: columns, spacing: gridSpacing) {
                    // Not `items`: the hero's game would otherwise repeat as
                    // the first tile directly beneath itself. `Shelf.gridItems`
                    // owns that rule and is where it is tested.
                    ForEach(Shelf.gridItems(from: items, heroZone: zone)) { item in
                        tile(for: item)
                    }
                    if Shelf.showsAddHint(itemCount: items.count) {
                        addHintTile
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
        // Pushed, not presented (spec §3.2): one page for every tile, and no
        // second sheet to promote after the first dismisses.
        .navigationDestination(item: $pageGame) { game in
            GamePageView(game: game, library: library,
                         onPlay: { play($0, mode: $1) },
                         onChanged: refresh,
                         onClose: { pageGame = nil })
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
        .sheet(isPresented: $showPlayerSettings, onDismiss: refresh) {
            PlayerSettingsView(library: library)
        }
        // The welcome card's Add Your Games opens the same importer the
        // toolbar's Add button and the ghost tile do, down to the accepted
        // types (spec §4).
        .wadFileImporter(isPresented: $showImporter, importer: importer) { _ in
            refresh()
        }
        .confirmationDialog(actionItem?.name ?? "", isPresented: actionDialogBinding,
                            titleVisibility: .visible, presenting: actionItem) { item in
            Button("Continue") { play(item, mode: .continueNewest) }
                .accessibilityIdentifier("continueAction")
            Button("New Game") { play(item, mode: .newGame) }
                .accessibilityIdentifier("newGameAction")
            Button("Details") { pageGame = item }
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
            Button {
                showImporter = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            // The one import door (spec §3.4): the welcome card and the ghost
            // tile call the same importer.
            .accessibilityIdentifier("importButton")
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
            tileMinimumWidth: Theme.gridMinimumTileWidth(for: dynamicTypeSize),
            contentPadding: contentPadding,
            gridSpacing: gridSpacing,
            fullCardHeight: ShelfHeroLayout.welcomeCardHeight(
                descriptionHeight: welcomeDescriptionHeight,
                buttonHeight: welcomeButtonHeight))
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
        // No app-name row (spec §4, amended 2026-08-21): the navigation title
        // directly above this card already says "Waddle", and a first launch
        // was greeting the player with the name twice in a row.
        VStack(alignment: .leading, spacing: 12) {
            // Dropped on viewports where the card would otherwise push the
            // first tile row past the fold -- see
            // `ShelfHeroLayout.welcomeCardShowsDescription`. The button is
            // what spec §4 leads with; the sentence is the part that can go
            // when "playable in one tap" is the thing at stake.
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
    private func hero(for game: Game) -> some View {
        Button {
            play(game, mode: .continueNewest)
        } label: {
            VStack(alignment: .leading, spacing: heroCaptionSpacing) {
                TitleArtView(game: game, library: library,
                             aspectRatio: Theme.heroAspectRatio,
                             height: ShelfHeroLayout.artHeight(
                                contentWidth: heroContentWidth,
                                viewportHeight: viewportHeight,
                                captionHeight: heroCaptionHeight))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius,
                                                style: .continuous))
                Text(game.name).font(.title2.bold())
                HStack(spacing: 4) {
                    // Continue is this screen's primary action, so it — and
                    // only it — wears the one red accent (spec §5). The
                    // last-played half stays secondary.
                    Group {
                        Image(systemName: "play.fill")
                        Text("Continue")
                    }
                    .foregroundStyle(Color.appAccent)
                    if let played = game.lastPlayed {
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
        .accessibilityLabel("Continue \(TileAccessibility.label(for: game))")
        .contextMenu { contextMenuItems(for: game) }
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
                .aspectRatio(Theme.tileAspectRatio, contentMode: .fit)
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
            case .openPage: pageGame = game
            }
        } label: {
            PlayableTileView(game: game, library: library)
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
        Button("Details") { pageGame = game }
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

    private func play(_ game: Game, mode: LaunchMode = .newGame) {
        lastExitCode = nil
        // Recorded before prepare() can throw: the user did try to start this
        // one, and a "session begin" with an immediate argument-failure end is
        // a truer trail than no begin at all.
        BreadcrumbLog.shared.record(.sessionBegin(name: game.name))
        do {
            let plan = try GameLauncher.prepare(game, library: library, mode: mode)
            let exitCode = EngineSession.play(arguments: plan.arguments, scheme: plan.scheme)
            lastExitCode = exitCode
            BreadcrumbLog.shared.record(
                .sessionEnd(exitCode: exitCode,
                            engineMessage: EngineSession.lastErrorMessage))
            present(EngineErrorAlert.from(exitCode: exitCode,
                                          engineMessage: EngineSession.lastErrorMessage))
        } catch {
            let message = "A file in this game is missing from the library."
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
        let all = (try? library.shelfGames()) ?? []
        items = Shelf.ordered(all)
        // A library that cannot be read is not a factory-state one: falling
        // back to `false` keeps a transient read failure from greeting a
        // player who has been here for months as a new arrival.
        zone = Shelf.heroZone(from: all,
                              isFactoryState: (try? library.isFactoryState()) ?? false,
                              hasResumableSave: hasResumableSave)
    }
}
