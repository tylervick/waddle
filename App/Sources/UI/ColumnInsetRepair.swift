import SwiftUI
import UIKit

/// Clears a trailing safe-area inset that the inspector's column leaves on
/// the shelf after UIKit has hidden the column (issue #496).
///
/// UIKit saves the inspector's column with the scene and brings it back at
/// the next launch, before anything of ours runs. SwiftUI refuses it
/// (`ShelfPanelModel.systemSetPresented`) and UIKit hides it again, but on
/// an open iPhone Duo it sometimes leaves the content column's trailing
/// safe-area inset at the column's width (364 pt) for good: the shelf and
/// its bar stay laid out in the left of the window beside an empty band.
/// Measured on the simulator, 2026-11-28: the inspector reported hidden and
/// out of the window, the inset still 364 six seconds later, and a forced
/// layout of the split view did not change it.
///
/// Changing the content column's `additionalSafeAreaInsets` makes UIKit
/// work its safe area out again, without the column. So when no column is
/// wanted, none is showing and the content column's trailing inset is still
/// larger than the window's, this moves the additional inset by a point and
/// back on the next turn. Public API only; nothing UIKit saved is touched.
struct ColumnInsetRepair: UIViewRepresentable {
    /// Whether the panel model wants the column up (`columnIsWanted`).
    let columnIsWanted: Bool

    func makeUIView(context: Context) -> RepairView {
        let view = RepairView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: RepairView, context: Context) {
        view.columnIsWanted = columnIsWanted
        view.scheduleCheck()
    }

    /// The split view SwiftUI's inspector is built on, and its content
    /// column, found from a view inside the shelf. Nil when there is none: a
    /// compact window, or a SwiftUI that no longer builds the inspector
    /// this way, in which case the repair does nothing
    /// (`ColumnInsetRepairTests` says so on every CI leg).
    static func contentColumn(containing view: UIView) -> (UISplitViewController, UIViewController)? {
        var responder: UIResponder? = view
        while let next = responder {
            if let split = next as? UISplitViewController {
                guard let content = split.viewController(for: .secondary), view.isDescendant(of: content.view)
                else { return nil }
                return (split, content)
            }
            responder = next.next
        }
        return nil
    }

    /// The decision, as a function a test can call.
    nonisolated static func needsRepair(columnIsWanted: Bool, columnIsShowing: Bool,
                                        contentTrailingInset: CGFloat, windowTrailingInset: CGFloat) -> Bool {
        !columnIsWanted && !columnIsShowing && contentTrailingInset > windowTrailingInset + 1
    }

    final class RepairView: UIView {
        var columnIsWanted = false
        private var pending: DispatchWorkItem?
        /// Repairs since the last time nothing needed one: a guard against
        /// a nudge that does not take, which must not loop.
        private var attempts = 0
        private static let maxAttempts = 3
        /// Long enough for UIKit to have finished hiding a column it brought
        /// back: the stray inset was there to stay by 0.8 s after launch.
        private static let settle: TimeInterval = 0.6

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleCheck()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            scheduleCheck()
        }

        func scheduleCheck() {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.check() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settle, execute: work)
        }


        private func trailing(_ insets: UIEdgeInsets) -> CGFloat {
            effectiveUserInterfaceLayoutDirection == .rightToLeft ? insets.left : insets.right
        }

        private func check() {
            guard let window, let found = ColumnInsetRepair.contentColumn(containing: self) else { return }
            let (split, content) = found
            let needed = ColumnInsetRepair.needsRepair(
                columnIsWanted: columnIsWanted,
                columnIsShowing: split.isShowing(.inspector),
                contentTrailingInset: trailing(content.view.safeAreaInsets),
                windowTrailingInset: trailing(window.safeAreaInsets))
            guard needed else { attempts = 0; return }
            guard attempts < Self.maxAttempts else { return }
            attempts += 1
            let original = content.additionalSafeAreaInsets
            var nudged = original
            nudged.right += 1
            content.additionalSafeAreaInsets = nudged
            DispatchQueue.main.async {
                content.additionalSafeAreaInsets = original
            }
        }
    }
}
