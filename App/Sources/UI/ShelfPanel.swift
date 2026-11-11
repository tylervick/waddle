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
        get { isPresented ? content : nil }
        set {
            // Opening or closing a panel settles what should be up; a close
            // still in flight would write over it.
            cancelStrayColumnClose()
            content = newValue
            isPresented = newValue != nil
        }
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
    func systemSetPresented(_ presented: Bool) {
        guard presented, content == nil else {
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
        if content == nil, let refused = refusedPresentationAt,
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
        guard content == nil, windowIsRegularWidth else { return }
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { isPresented = true }
        strayColumnTask = Task { @MainActor in
            // A frame or so: written back in the same pass, the two writes
            // cancel out and SwiftUI sees no change.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, self.content == nil else { return }
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
        if content == nil, isPresented {
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
    var opensInPanel: Bool { Self.opensInPanel(regularWidth: windowIsRegularWidth) }

    /// The whole rule, as a function a test can call: a regular-width window
    /// gets the panel, a compact one keeps the page and the sheet.
    nonisolated static func opensInPanel(regularWidth: Bool) -> Bool { regularWidth }
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
        switch model.content {
        case .game(let game):
            NavigationStack {
                GamePageView(game: game, library: library,
                             onPlay: { model.play($0, $1) },
                             onChanged: { model.changed() },
                             onClose: { model.panel = nil })
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
            PlayerSettingsView(library: library, onDone: { model.panel = nil })
        case nil:
            EmptyView()
        }
    }
}
