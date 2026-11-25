import SwiftUI
import UIKit
#if DEBUG
import notify
#endif

/// Reads the fold for the launcher (issue #429): reports the two halves of
/// the window while an iPhone Duo stands half open with the fold across it,
/// and `nil` in every other pose and on every other device.
///
/// It asks the system the two things `TouchOverlayView` asks during a
/// session, and gives them to the same `HalfOpenSplit`, so the launcher and
/// the session part at the same band under the same condition. See
/// `docs/learnings/iphone-duo-half-open-pose.md` for what the system reports
/// and why neither reading is enough alone.
///
/// Installed under the launcher's root view through UIKit, pinned to its safe
/// area, so its bounds are the root's and the rects it reports are in the
/// root's own coordinates.
/// Nothing here measures the launcher's content: the halves come from the
/// device and the window alone (issue #437 is what a layout fed by its own
/// content costs).
///
/// It was a `UIViewRepresentable` in the root's background first. That put a
/// UIKit view inside SwiftUI's own tree for the sake of two readings that
/// have nothing to do with drawing; here it is beside the tree instead.
/// `docs/learnings/parting-the-launcher-at-the-fold.md` has what CI showed
/// with each, which was not enough to blame either.
@MainActor
enum LauncherFold {
    private static weak var reader: LauncherFoldReaderView?

    /// Starts reporting the fold to `onChange`, on the main thread: once
    /// with the first answer and again whenever it changes. Called when the
    /// root view appears; a second call replaces the handler.
    static func follow(_ onChange: @escaping (HalfOpenSplit?) -> Void) {
        if let reader {
            reader.onChange = onChange
            return
        }
        guard let root = launcherRootView() else {
            // The root view can appear a moment before its window is the
            // scene's; ask again on the next pass.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(50))
                follow(onChange)
            }
            return
        }
        let view = LauncherFoldReaderView()
        view.onChange = onChange
        view.translatesAutoresizingMaskIntoConstraints = false
        root.insertSubview(view, at: 0)
        let safe = root.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: safe.topAnchor),
            view.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
        ])
        reader = view
    }

    /// Takes down the alert or confirmation dialog the launcher's window has
    /// up, if any, when the pose changes (issue #520). Called once the swap
    /// of the panel's trees has begun to hold presentations
    /// (`ShelfPanelModel.presentationsHeld`), so the write that comes with
    /// the dismissal is refused and the next tree puts the dialog up again.
    ///
    /// The tree going away was trusted to dismiss its own dialog as its
    /// binding read false. On an iPad it sometimes did not: opened flat, the
    /// lower half's save warning stayed up as an orphaned popover over the
    /// shelf, its arrow pointing at nothing, and the column's warning did
    /// not come up while it was there. Holding presentations a main-queue
    /// turn before taking the tree away still left the orphan in 1 run of 2.
    ///
    /// Only alerts and dialogs: a sheet is the panel's own form on a compact
    /// window, and SwiftUI moves it. And only when the panel has one up
    /// (`ShelfPanelModel.panelHasDialogUp`): called on every change of pose,
    /// this took down the shelf's tile actions and the engine's error
    /// alert, whose trees survive the fold, and dropped them (review of
    /// pull request 524).
    static func dismissDialogs() {
        var presenter = launcherRootView()?.window?.rootViewController
        while let presented = presenter?.presentedViewController {
            if presented is UIAlertController {
                if !presented.isBeingDismissed { presenter?.dismiss(animated: true) }
                return
            }
            presenter = presented
        }
    }

    /// Whether the launcher's window is presenting or dismissing anything:
    /// a view controller in its chain of presentations being presented or
    /// dismissed, or one with a transition under way. A presentation begun
    /// then, from the presenter the transition is on, is refused by UIKit
    /// (`ShelfPanelModel.presentationsHeld` waits for this to clear).
    ///
    /// On the bend with the save warning up, two dismissals follow each
    /// other: the warning's (the alert `isBeingDismissed`), then the
    /// inspector's sheet under it (the sheet `isBeingDismissed`, the root
    /// with a transition coordinator). Sampled every 5 ms on the simulator,
    /// in three runs, this read true without a break from the first to the
    /// end of the second (2026-11-24).
    static func presentationTransitionInFlight() -> Bool {
        var controller = launcherRootView()?.window?.rootViewController
        while let current = controller {
            if current.isBeingPresented || current.isBeingDismissed || current.transitionCoordinator != nil {
                return true
            }
            controller = current.presentedViewController
        }
        return false
    }

    /// The view SwiftUI draws the launcher in: the root of the app's first
    /// window. The engine's window does not exist until a session starts.
    private static func launcherRootView() -> UIView? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first?.rootViewController?.view
    }
}

final class LauncherFoldReaderView: UIView {
    var onChange: ((HalfOpenSplit?) -> Void)?

    private var hingePartiallyOpen = false
    private var split: HalfOpenSplit?
    private var reported = false
    private var bandPoll: Timer?
    #if DEBUG
    /// `WADDLE_TEST_HALF_OPEN`, the seam `TouchOverlayView` has: non-nil
    /// while it is in use. See `installTestSeam()`.
    private var testHalfOpen: Bool?
    private var testToggleToken: Int32?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Behind the launcher and never a target: it only reads.
        isUserInteractionEnabled = false
        backgroundColor = .clear
        observeHinge()
        #if DEBUG
        installTestSeam()
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The API is iOS 27.1's. On anything older there is no hinge, the flag
    /// stays false and the launcher never parts.
    private func observeHinge() {
        guard #available(iOS 27.1, *) else { return }
        addInteraction(UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            hingePartiallyOpen = update.hinge?.status == .partiallyOpen
            followBandWhileBent()
            refresh()
        })
    }

    /// The band turns active about a third of a second after the hinge reads
    /// partly open, and nothing announces it, so it is asked for while the
    /// hinge is bent and not otherwise: a flat or closed device, and every
    /// device without a hinge, runs no timer. Opening flat needs none, since
    /// the hinge's own reading ends the split.
    private func followBandWhileBent() {
        guard hingePartiallyOpen, window != nil else {
            bandPoll?.invalidate()
            bandPoll = nil
            return
        }
        guard bandPoll == nil else { return }
        bandPoll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Leaving the window is where the timer and the seam's registration end,
    /// not `deinit`, which Swift 6 will not let touch either.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        followBandWhileBent()
        #if DEBUG
        if window == nil, let token = testToggleToken {
            notify_cancel(token)
            testToggleToken = nil
        } else if window != nil, testHalfOpen != nil, testToggleToken == nil {
            registerTestToggle()
        }
        #endif
        refresh()
    }

    /// The band's frame follows the bounds, so a turned or resized window is
    /// read again here.
    override func layoutSubviews() {
        super.layoutSubviews()
        refresh()
    }

    private var foldDivisions: [FoldDivision] {
        #if DEBUG
        if testHalfOpen != nil {
            // A band the Duo's size across the middle of the window.
            return [FoldDivision(frame: CGRect(x: bounds.minX, y: bounds.midY - 20,
                                               width: bounds.width, height: 40),
                                 isActive: true)]
        }
        #endif
        guard #available(iOS 27.1, *) else { return [] }
        return reservedRegions(kind: .division, options: [.includeInactive])
            .map { FoldDivision(frame: $0.frame, isActive: $0.isActive) }
    }

    private func refresh() {
        guard window != nil else { return }
        var partiallyOpen = hingePartiallyOpen
        #if DEBUG
        if let testHalfOpen { partiallyOpen = testHalfOpen }
        #endif
        let now = HalfOpenSplit(bounds: bounds, hingePartiallyOpen: partiallyOpen,
                                divisions: foldDivisions)
        guard now != split || !reported else { return }
        split = now
        reported = true
        // Not inside this layout pass: the answer changes SwiftUI state, and
        // `layoutSubviews` is one of the callers.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            onChange?(split)
        }
    }

    #if DEBUG
    /// `WADDLE_TEST_HALF_OPEN=1` starts the launcher as if the device stood
    /// half open with the fold across the middle of the window; any other
    /// value starts it flat with the seam armed. The Darwin notification
    /// flips it. Both are the session's (`TouchOverlayView`), so one test
    /// can fold the launcher and the session after it the same way.
    private func installTestSeam() {
        guard let value = ProcessInfo.processInfo.environment["WADDLE_TEST_HALF_OPEN"] else { return }
        testHalfOpen = value != "0" && value != "stick"
    }

    private func registerTestToggle() {
        var token: Int32 = 0
        let status = notify_register_dispatch(TouchOverlayView.testHalfOpenToggleNotification,
                                              &token, .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let current = self.testHalfOpen else { return }
                self.testHalfOpen = !current
                self.refresh()
            }
        }
        if status == 0 { testToggleToken = token }
    }
    #endif
}
