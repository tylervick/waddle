import SwiftUI

/// Where the panel's screens keep what they have pushed and presented
/// (issue #429, from the review of pull request 461).
///
/// The panel is drawn by more than one view tree: the inspector's column on a
/// flat device, the lower half on a half-open iPhone Duo, and on a compact
/// window the shelf's own sheet and pushed page. Bending the device or
/// opening it flat takes one tree down and puts another up. While this state
/// was `@State` inside those trees a fold reset it: Settings > Files came
/// back as Settings, and a save warning waiting for an answer was gone.
///
/// So it lives here, on `ShelfPanelModel`, and every tree reads the same
/// object. Two rules make that safe, and both are in `PanelHost`:
///
/// - **Only the tree that is on screen may write.** A tree being taken down
///   dismisses what it had presented, and the write that goes with a
///   dismissal must not reach the state the next tree is about to show.
/// - **A presentation is put up again, not carried.** A sheet, alert or
///   dialog belongs to the tree that presented it and goes down with it.
///   The state says it is still wanted, and the next tree presents it once
///   the swap has settled (`ShelfPanelModel.presentationsHeld`).
@MainActor
@Observable
final class SettingsPresentation {
    /// Screens pushed over Settings, outermost last.
    enum Route: Hashable {
        case files
        case hiddenGames
        case about
        case license(title: String, filename: String)
    }

    var path: [Route] = []
    /// Control Feel: a sheet on a flat device, pushed in the lower half.
    var showControlFeel = false
    /// The layout editor, over Control Feel.
    var showLayoutEditor = false
    /// Files' "File in use" alert.
    var filesDeleteBlocked: [FilesView.BlockedFile] = []
    /// About's share sheet and its failure alert.
    var exportedZip: URL?
    var exportError: String?
}

/// The same for one game's page.
@MainActor
@Observable
final class GamePagePresentation {
    var showRename = false
    var draftName = ""
    var showAddFile = false
    /// The file the Add… picker picked, staged until the picker has gone.
    var pendingAdd: WADFile?
    /// A base or file edit waiting on the change-with-saves confirmation.
    var pendingEdit: GameEdit?
    var deleteCandidate: Game?

    /// Whether anything is up or waiting for an answer. A resting page in
    /// this state is kept as an open panel when the device is opened flat,
    /// so the question is not dropped with the lower half.
    var isAwaitingAnAnswer: Bool {
        showRename || showAddFile || pendingAdd != nil || pendingEdit != nil || deleteCandidate != nil
    }
}

/// What a tree that draws the panel tells the screens inside it: which tree
/// it is. Whether that tree is the one on screen is then asked of the model
/// each time, never remembered.
///
/// It has to be asked live. The first version handed each tree a pair of
/// flags worked out when the tree was last drawn, and a binding kept the
/// pair it was made with. A column on its way down after the device was
/// bent still held "current", so the write that came with its alert's
/// dismissal went through and cleared the state the lower half was about to
/// show: the rename alert survived opening flat and was lost on bending
/// (seen on the simulator's hinge, 2026-11-22; the compact window a UI test
/// has did not show it).
@MainActor
struct PanelHost {
    enum Tree {
        /// The inspector's column, and on a compact window the shelf's own
        /// sheet and pushed page: everything that is the panel while the
        /// launcher is whole.
        case whole
        /// The lower half of a parted launcher.
        case lowerHalf
    }

    /// Nil for a screen nothing shares: always current, never held.
    weak var model: ShelfPanelModel?
    var tree: Tree = .whole

    nonisolated init() {}

    init(model: ShelfPanelModel, tree: Tree) {
        self.model = model
        self.tree = tree
    }

    /// This tree is the one on screen for the pose the device is in. Only
    /// then may its screens write to the shared state.
    var isCurrent: Bool {
        guard let model else { return true }
        return model.isSplit == (tree == .lowerHalf)
    }

    /// Whether a screen in this tree should have its presentations up: it
    /// is current, and no swap of trees is still settling.
    var presents: Bool { isCurrent && !(model?.presentationsHeld ?? false) }

    /// A presentation's binding over shared state: read as down unless this
    /// tree presents, and written only while it does.
    func presented(_ get: @escaping @MainActor () -> Bool,
                   dismiss: @escaping @MainActor () -> Void,
                   present: @escaping @MainActor () -> Void = {}) -> Binding<Bool> {
        Binding(get: { presents && get() },
                set: { up in
                    guard presents else { return }
                    if up { present() } else { dismiss() }
                })
    }
}

extension EnvironmentValues {
    /// Set by each tree that draws the panel; the default is a screen that
    /// is simply on screen, as on a phone.
    @Entry var panelHost = PanelHost()
}
