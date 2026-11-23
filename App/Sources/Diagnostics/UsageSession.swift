import Foundation
import UIKit

/// One engine session's usage counting (issue #487, reviews of pull request
/// 491).
///
/// Leaving the app does not end a session, and neither does any other
/// interruption: the engine pauses the moment the app resigns active (SDL
/// turns `applicationWillResignActive` into `SDL_EVENT_WILL_ENTER_BACKGROUND`,
/// and `i_video.c`'s lifecycle watch calls `G_BackgroundPause` on it), and
/// saves once it is in the background. So the clock runs only while the app
/// is active. That leaves out the app switcher, Control Center, Notification
/// Center, a call banner and Siri, as well as the background itself.
///
/// Each resign writes the active time so far to disk and leaves a marker;
/// becoming active again clears it. The resign, not the background, is the
/// moment to do it: flicking the app away in the switcher, the commonest way
/// a game is killed, resigns active and is never told it entered the
/// background. The next launch counts a marker it finds as a session that
/// ended while inactive, not as a crash, and a crash while active still
/// leaves no marker.
///
/// UIKit posts the two notifications on the main thread from inside the
/// engine's own run-loop pump, so the observers run between tics, the same
/// place the engine's lifecycle watch runs.
@MainActor
final class UsageSession {
    let bucket: UsageGameBucket
    private let store: UsageStore
    private let center: NotificationCenter
    private let now: () -> Date
    /// When the current active stretch began; nil while inactive.
    private var activeSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var ended = false

    /// `startsActive` is false for a session started while the app is not
    /// active: the clock then waits for the app to become active.
    init(store: UsageStore, bucket: UsageGameBucket, scheme: TouchControlScheme,
         controllerConnected: Bool, orientation: UsageOrientation,
         startsActive: Bool = true,
         center: NotificationCenter = .default,
         now: @escaping () -> Date = { .now }) {
        self.store = store
        self.bucket = bucket
        self.center = center
        self.now = now
        store.recordSessionStart(bucket: bucket, scheme: scheme,
                                 controllerConnected: controllerConnected,
                                 orientation: orientation, at: now())
        if startsActive {
            activeSince = now()
        } else {
            store.recordSessionInactive(bucket: bucket, playTime: 0)
        }
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification,
                               object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.willResignActive() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                               object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.didBecomeActive() }
            },
        ]
    }

    func willResignActive() {
        guard !ended, let since = activeSince else { return }
        activeSince = nil
        store.recordSessionInactive(bucket: bucket, playTime: now().timeIntervalSince(since))
    }

    func didBecomeActive() {
        guard !ended, activeSince == nil else { return }
        activeSince = now()
        store.recordSessionActive()
    }

    /// The engine returned. Only the active stretch still running is added:
    /// everything before it was saved when the app last resigned active.
    func end(exitCode: Int32) {
        guard !ended else { return }
        ended = true
        for observer in observers { center.removeObserver(observer) }
        observers = []
        let remaining = activeSince.map { now().timeIntervalSince($0) } ?? 0
        activeSince = nil
        store.recordSessionEnd(bucket: bucket, exitCode: exitCode,
                               playTime: remaining, at: now())
    }
}
