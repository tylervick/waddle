import SwiftUI

/// What the shelf has open beside it on a regular-width window (issue #372).
enum ShelfPanel: Equatable {
    case game(Game)
    case settings

    static func == (lhs: ShelfPanel, rhs: ShelfPanel) -> Bool {
        switch (lhs, rhs) {
        case (.settings, .settings): return true
        case let (.game(a), .game(b)): return a.id == b.id
        default: return false
        }
    }

    /// The game this panel is showing, for the shelf to mark its tile.
    var gameID: UUID? {
        if case .game(let game) = self { return game.id }
        return nil
    }
}

/// The shelf's panel, held where both the shelf and the app's root can reach
/// it.
///
/// ## Why this is not `@State` in `ShelfView`
///
/// The panel is a SwiftUI inspector, and an inspector has to be attached
/// outside the shelf's `NavigationStack`. Attached inside it, on an iPhone Duo
/// the shelf's wordmark is centred across both columns and straddles the
/// divider, and after a rotation the column disappears while its Done button
/// stays in the shelf's bar (measured on the simulator, 2026-11-10; the
/// record is on issue #372). So `ContentView` owns the inspector, and what it
/// shows has to live somewhere both views see.
///
/// The two closures are the shelf's own `play` and `refresh`. The panel's
/// content is built at the root, but starting a session and reloading the
/// shelf are the shelf's business, and it registers them here when it
/// appears.
@MainActor
@Observable
final class ShelfPanelModel {
    /// What the panel shows, or nil when nothing is open.
    ///
    /// Separate from `isPresented` on purpose. When an iPhone Duo folds or
    /// unfolds, the inspector is torn down as a column and put back as a
    /// sheet (or the reverse), and SwiftUI writes `false` and then `true` to
    /// its binding on the way. Deriving presentation from this being non-nil
    /// lost the panel on the first fold, because the `false` cleared it and
    /// the `true` had nothing to show (seen on the simulator, 2026-11-10).
    /// So a `false` from the system hides the panel and keeps this; only
    /// closing it through `panel = nil` forgets it.
    private(set) var content: ShelfPanel?

    /// Whether the inspector is up. Read by its binding; written only
    /// through `panel` and `systemSetPresented`.
    private(set) var isPresented = false

    /// What is open right now, or nil. Setting it opens or closes the panel.
    var panel: ShelfPanel? {
        get { (isSplit ? openInLowerHalf : isPresented || columnIsReturning) ? content : nil }
        set {
            // Opening or closing a panel settles what should be up; a close
            // still in flight would write over it.
            cancelStrayColumnClose()
            cancelColumnReturn()
            forgetPresentation(of: content, replacedBy: newValue)
            content = newValue
            if isSplit {
                openInLowerHalf = newValue != nil
            } else {
                isPresented = newValue != nil
            }
        }
    }

    // MARK: Two halves (issue #429)

    /// Whether the launcher is in two halves: an iPhone Duo standing half
    /// open with the fold across the window. The shelf has the upper half
    /// and the panel the lower one, at full width, and the inspector is not
    /// used at all: `isPresented` stays false for as long as this is true.
    ///
    /// Presentation in this pose is `openInLowerHalf`, a property of its
    /// own for the reason `content` is separate from `isPresented`: the
    /// inspector writes to its binding while it is taken down, and what the
    /// player has open must not depend on what it writes.
    private(set) var isSplit = false

    /// Whether the player has a panel open while the launcher is in two
    /// halves. Meaningless otherwise.
    private var openInLowerHalf = false

    /// The game whose page the lower half shows while nothing is open there:
    /// the first game on the shelf, which is the last one played
    /// (`Shelf.restingGame`). The shelf sets it each time it reloads.
    var restingGame: Game?

    /// What the lower half shows: the open panel, or the resting game's
    /// page, or nil when the shelf has no game at all.
    var lowerHalf: ShelfPanel? { panel ?? restingGame.map(ShelfPanel.game) }

    // MARK: What the panel's screens have pushed and presented

    /// Settings' pushed screens and presentations, shared by every tree
    /// that draws Settings. See `SettingsPresentation`.
    private(set) var settingsPresentation = SettingsPresentation()

    /// One per game whose page has been drawn. Not observed: a page asks for
    /// its own while it is being drawn.
    @ObservationIgnored private var gamePagePresentations: [UUID: GamePagePresentation] = [:]

    /// The presentation state of `game`'s page, the same object for every
    /// tree that draws that page.
    func gamePagePresentation(for game: Game) -> GamePagePresentation {
        if let existing = gamePagePresentations[game.id] { return existing }
        let fresh = GamePagePresentation()
        gamePagePresentations[game.id] = fresh
        return fresh
    }

    /// A page the shelf pushed has been popped: its state goes with it,
    /// unless that game is now the panel (the page moved, it did not close).
    func pageClosed(_ game: Game) {
        if content?.gameID != game.id { gamePagePresentations[game.id] = nil }
    }

    /// The shelf's Settings sheet has been dismissed: the same, for Settings.
    func settingsSheetClosed() {
        if content != .settings { settingsPresentation = SettingsPresentation() }
    }

    /// Closing a panel, or opening another over it, forgets where the old
    /// one had got to. A panel that is merely moving between trees does not
    /// come through here with a different value.
    private func forgetPresentation(of old: ShelfPanel?, replacedBy new: ShelfPanel?) {
        guard old != new else { return }
        switch old {
        case .settings: settingsPresentation = SettingsPresentation()
        case .game(let game): gamePagePresentations[game.id] = nil
        case nil: break
        }
    }

    /// True while one tree is replacing another, and for a moment after.
    /// Screens keep their sheets, alerts and dialogs down while it is, and
    /// put them up again when it clears.
    ///
    /// What it waits for is the old tree's presentations finishing their
    /// dismissal. A presentation begun while another is still leaving the
    /// same presenter is refused by UIKit, and SwiftUI then believes it is
    /// up. Nothing reports the end of a dismissal to a tree that no longer
    /// exists, so this is a duration: longer than the system's dismissal
    /// (about a third of a second for a sheet), and long enough for a
    /// compact window's inspector sheet to have arrived for the screen
    /// inside it to present from.
    private(set) var presentationsHeld = false
    @ObservationIgnored private var presentationHoldTask: Task<Void, Never>?
    static let presentationHold: Duration = .milliseconds(700)

    private func holdPresentationsAcrossSwap() {
        presentationHoldTask?.cancel()
        presentationsHeld = true
        presentationHoldTask = Task { @MainActor in
            try? await Task.sleep(for: Self.presentationHold)
            guard !Task.isCancelled else { return }
            self.presentationHoldTask = nil
            self.presentationsHeld = false
        }
    }

    /// What the column's tree tells its screens.
    var columnHost: PanelHost { PanelHost(model: self, tree: .whole) }
    /// What the lower half's tree tells its screens.
    var lowerHalfHost: PanelHost { PanelHost(model: self, tree: .lowerHalf) }

    /// The game whose page is on screen, for the shelf to mark its tile: the
    /// open panel's, or in two halves the resting page's too.
    var shownGameID: UUID? { (isSplit ? lowerHalf : panel)?.gameID }

    /// The root reports the pose here: `true` when the launcher parts in
    /// two, `false` when it is whole again.
    ///
    /// A panel that was open stays open across the change, both ways. Going
    /// in, the column is taken down where SwiftUI can see it (a change to
    /// the binding, with animations off, as `closeStrayColumn` does); coming
    /// out, it is put back up (`returnColumn`).
    func foldChanged(isSplit split: Bool) {
        guard split != isSplit else { return }
        // Asked first: a column still on its way back up counts as open, and
        // the next line forgets that it was.
        var wasOpen = panel != nil
        // A resting page with a question up (a save warning, a rename) is
        // not open in this sense, and opening flat would take the lower
        // half and the question away. It becomes the open panel instead.
        if !split, !wasOpen, let resting = restingGame,
           gamePagePresentations[resting.id]?.isAwaitingAnAnswer == true {
            content = .game(resting)
            wasOpen = true
        }
        holdPresentationsAcrossSwap()
        // While `isSplit` still has its old value, so a close in flight is
        // taken back under the rules it was started under.
        cancelStrayColumnClose()
        cancelColumnReturn()
        var quiet = Transaction()
        quiet.disablesAnimations = true
        if split {
            openInLowerHalf = wasOpen
            isSplit = true
            withTransaction(quiet) { isPresented = false }
        } else {
            let open = wasOpen
            isSplit = false
            openInLowerHalf = false
            // Closed in the lower half is closed: nothing is left for a
            // later write from the system to bring back.
            if !open {
                forgetPresentation(of: content, replacedBy: nil)
                content = nil
            }
            if open { returnColumn() }
        }
    }

    /// True between the launcher becoming whole and the column going back
    /// up, so that `panel` does not report a moment with nothing open.
    private var columnIsReturning = false
    @ObservationIgnored private var columnReturnTask: Task<Void, Never>?

    /// Puts the column back up on the main queue's next turn after the
    /// launcher became whole.
    ///
    /// The ordering it relies on: the pass that takes the lower half away
    /// has ended before the binding is written. Written inside that pass,
    /// alongside the change of layout, the `true` was read back from the
    /// binding and nothing was shown: on the simulator, 2026-11-21, the
    /// column failed to come back in 3 of 5 openings, with animations on or
    /// off. `foldChanged` is called from the fold reader's own main-queue
    /// block, the one that also sets the root's `halves`, so a block queued
    /// behind it runs after SwiftUI has finished with that change. With the
    /// write there the column came back in 6 of 6 (three fresh launches,
    /// each opened flat twice). An earlier version waited 80 ms instead,
    /// which also worked and said nothing about what it was waiting for.
    /// It is the mirror of `closeStrayColumn`, where two writes in one pass
    /// cancel out.
    private func returnColumn() {
        columnIsReturning = true
        columnReturnTask = Task { @MainActor in
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { done.resume() }
            }
            guard !Task.isCancelled else { return }
            self.columnReturnTask = nil
            self.columnIsReturning = false
            guard !self.isSplit, self.content != nil else { return }
            self.isPresented = true
        }
    }

    private func cancelColumnReturn() {
        columnReturnTask?.cancel()
        columnReturnTask = nil
        columnIsReturning = false
    }

    /// The inspector's own writes to its binding.
    ///
    /// These cannot be taken at their word. On a regular-width window
    /// SwiftUI writes `true` here with nothing open: measured on an iPad and
    /// a landscape iPhone 17 Pro Max a moment after launch, 2026-11-10,
    /// where accepting it put an empty column beside the shelf. So `true`
    /// is honoured only when there is something to show, which is exactly
    /// the fold case above.
    ///
    /// With nothing to show there are two cases, and they need opposite
    /// answers:
    ///
    /// - **At launch, or on a phone's rotation**, refusing is enough. The
    ///   column never appears.
    /// - **When an iPhone Duo has just been unfolded**, refusing is not
    ///   enough. SwiftUI has put the column up, and having had its write
    ///   refused it does not look at the binding again: the empty column
    ///   stays. It only takes a column down for a change it can see. So in
    ///   the moments after the window becomes regular width the write is
    ///   *accepted*, which makes this model and SwiftUI agree that the
    ///   column is up, and then taken back a frame later with animations
    ///   off, which SwiftUI acts on.
    ///
    /// An earlier version bounced the binding on a timer after the width
    /// change instead. It raced the system: on the first unfold after
    /// launch the column went up after the bounce had already run.
    /// Reacting to the write itself has nothing to race.
    ///
    /// In two halves (`isSplit`) the column is never wanted, whatever is
    /// open, so every `true` there is one of the two cases above.
    func systemSetPresented(_ presented: Bool) {
        guard presented, content == nil || isSplit else {
            isPresented = presented && content != nil
            return
        }
        if windowJustBecameRegular {
            closeStrayColumn()
        } else {
            refusedPresentationAt = ContinuousClock.now
            isPresented = false
        }
    }

    /// The root reports the window's width class here. `becameRegular` is
    /// the transition from compact (an unfold), as opposed to a window that
    /// was regular from the start.
    func windowWidthChanged(isRegular: Bool, becameRegular: Bool) {
        windowIsRegularWidth = isRegular
        guard isRegular else {
            // In a compact window an accepted `true` would be an empty
            // sheet; whatever was in flight is abandoned.
            becameRegularAt = nil
            cancelStrayColumnClose()
            return
        }
        guard becameRegular else { return }
        becameRegularAt = ContinuousClock.now
        // The other order: SwiftUI's write arrived, and was refused, just
        // before this notification did. The column is already up.
        if content == nil || isSplit, let refused = refusedPresentationAt,
           refused.duration(to: ContinuousClock.now) < Self.strayColumnWindow {
            closeStrayColumn()
        }
    }

    /// How long after the window becomes regular width a `true` with nothing
    /// to show is treated as the unfold's stray column.
    private static let strayColumnWindow: Duration = .seconds(3)

    @ObservationIgnored private var becameRegularAt: ContinuousClock.Instant?
    @ObservationIgnored private var refusedPresentationAt: ContinuousClock.Instant?
    @ObservationIgnored private var strayColumnTask: Task<Void, Never>?

    private var windowJustBecameRegular: Bool {
        guard let since = becameRegularAt else { return false }
        return since.duration(to: ContinuousClock.now) < Self.strayColumnWindow
    }

    /// Agree that the column is up, then take it down where SwiftUI can see.
    private func closeStrayColumn() {
        cancelStrayColumnClose()
        guard content == nil || isSplit, windowIsRegularWidth else { return }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { isPresented = true }
        strayColumnTask = Task { @MainActor in
            // A frame or so: written back in the same pass, the two writes
            // cancel out and SwiftUI sees no change.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, self.content == nil || self.isSplit else { return }
            withTransaction(quiet) { self.isPresented = false }
            self.strayColumnTask = nil
        }
    }

    /// Abandons a close in flight. One that had already agreed the column
    /// was up takes that back, unless a panel has been opened since.
    private func cancelStrayColumnClose() {
        guard let task = strayColumnTask else { return }
        task.cancel()
        strayColumnTask = nil
        if content == nil || isSplit, isPresented {
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { isPresented = false }
        }
    }

    /// Whether the window is wide enough for a panel at all: regular
    /// horizontal size class, read at the root. Not read inside the shelf,
    /// whose own column narrows the moment a panel opens beside it.
    private(set) var windowIsRegularWidth = false

    var play: (Game, LaunchMode) -> Void = { _, _ in }
    var changed: () -> Void = {}

    /// Whether Details and Settings open in the panel (`true`) or the way a
    /// phone has them, as a pushed page and a sheet (`false`).
    var opensInPanel: Bool {
        Self.opensInPanel(regularWidth: windowIsRegularWidth, isSplit: isSplit)
    }

    /// The whole rule, as a function a test can call: a regular-width window
    /// gets the panel, a compact one keeps the page and the sheet. In two
    /// halves the panel is the lower half whatever the width: a pushed page
    /// would take the shelf's half, and a sheet would lie across the fold.
    nonisolated static func opensInPanel(regularWidth: Bool, isSplit: Bool = false) -> Bool {
        regularWidth || isSplit
    }
}

/// The inspector's content: a game's page or Settings, each in its own
/// navigation stack so Files, Hidden Games and About push inside the panel.
struct ShelfPanelView: View {
    let model: ShelfPanelModel
    let library: LibraryService

    var body: some View {
        // `content`, not `panel`: the inspector asks for its content while it
        // is being put back after a fold, a moment at which `isPresented` has
        // been written false and not yet true again.
        Group {
        switch model.content {
        case .game(let game):
            NavigationStack {
                GamePageView(game: game, library: library,
                             onPlay: { model.play($0, $1) },
                             onChanged: { model.changed() },
                             onClose: { model.panel = nil },
                             presentation: model.gamePagePresentation(for: game))
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { model.panel = nil }
                                .accessibilityIdentifier("panelDoneButton")
                        }
                    }
            }
            // A different game is a different page, not the same page with
            // new arguments: its saves, files and pickers are all `@State`.
            .id(game.id)
        case .settings:
            PlayerSettingsView(library: library, onDone: { model.panel = nil },
                               presentation: model.settingsPresentation)
        case nil:
            EmptyView()
        }
        }
        .environment(\.panelHost, model.columnHost)
    }
}

/// The lower half of the launcher while it is in two halves (issue #429):
/// the open panel, or the last-played game's page while nothing is open, so
/// Play is always under the thumb.
///
/// The same pages the inspector shows, in the same navigation stacks. Two
/// things differ, and `launcherIsInTwoHalves` in the environment is how the
/// pages know: what they would present as a sheet they push instead, since a
/// sheet covers the window and lies across the fold; and the resting page has
/// no Done, there being nothing behind it to go back to.
struct LowerHalfPanelView: View {
    let model: ShelfPanelModel
    let library: LibraryService

    var body: some View {
        Group {
            switch model.lowerHalf {
            case .game(let game):
                NavigationStack {
                    GamePageView(game: game, library: library,
                                 onPlay: { model.play($0, $1) },
                                 onChanged: { model.changed() },
                                 // The resting page closes to the shelf's
                                 // next answer; `changed` has already asked.
                                 onClose: { model.panel = nil },
                                 presentation: model.gamePagePresentation(for: game))
                        .toolbar {
                            if model.panel != nil {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") { model.panel = nil }
                                        .accessibilityIdentifier("panelDoneButton")
                                }
                            }
                        }
                }
                .id(game.id)
            case .settings:
                PlayerSettingsView(library: library, onDone: { model.panel = nil },
                                   presentation: model.settingsPresentation)
            case nil:
                // Every game hidden or deleted: the shelf above says so with
                // its Add tile, and there is no page to show.
                Color.appBackground
            }
        }
        .environment(\.launcherIsInTwoHalves, true)
        .environment(\.panelHost, model.lowerHalfHost)
    }
}

extension EnvironmentValues {
    /// True inside the lower half of a launcher that has parted at the fold
    /// (issue #429). A page there pushes what it would otherwise present as
    /// a sheet.
    @Entry var launcherIsInTwoHalves = false
}
