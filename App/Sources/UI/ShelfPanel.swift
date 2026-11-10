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
    /// What the panel shows. Kept when the panel closes, and separate from
    /// `isPresented`, on purpose: when an iPhone Duo folds or unfolds, the
    /// inspector is torn down as a column and put back as a sheet (or the
    /// reverse), and SwiftUI writes `false` and then `true` to its binding
    /// on the way. Deriving presentation from this being non-nil lost the
    /// panel on the first fold, because the `false` cleared it and the
    /// `true` had nothing to show (seen on the simulator, 2026-11-10).
    private(set) var content: ShelfPanel?

    /// Whether the inspector is up. Bound to it directly.
    var isPresented = false

    /// What is open right now, or nil. Setting it opens or closes the panel.
    var panel: ShelfPanel? {
        get { isPresented ? content : nil }
        set {
            if let newValue {
                content = newValue
                isPresented = true
            } else {
                isPresented = false
            }
        }
    }

    /// Whether the window is wide enough for a panel at all: regular
    /// horizontal size class, read at the root. Not read inside the shelf,
    /// whose own column narrows the moment a panel opens beside it.
    var windowIsRegularWidth = false

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
