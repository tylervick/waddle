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
/// Put behind the root view, so its bounds are the root's and the rects it
/// reports are in the root's own coordinates.
/// Nothing here measures the launcher's content: the halves come from the
/// device and the window alone (issue #437 is what a layout fed by its own
/// content costs).
struct LauncherFoldReader: UIViewRepresentable {
    /// Called on the main thread whenever the answer changes, and once with
    /// the first answer.
    let onChange: (HalfOpenSplit?) -> Void

    func makeUIView(context: Context) -> LauncherFoldReaderView {
        let view = LauncherFoldReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: LauncherFoldReaderView, context: Context) {
        view.onChange = onChange
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
        return []
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
