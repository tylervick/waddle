import Foundation
import UIKit

/// One engine session's usage counting (issue #487, review of pull request
/// 491).
///
/// Backgrounding does not end a session: the engine pauses and saves
/// (`G_BackgroundPause`, `G_BackgroundSave`) and the session goes on when the
/// app returns. So the clock runs only while the app is in the foreground,
/// and each trip to the background writes the foreground time so far to
/// disk. If iOS then reclaims the process, or the user swipes it away, the
/// minutes are already kept, and the next launch counts the session as ended
/// in the background rather than leaving it to read as a crash.
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
    /// When the current foreground stretch began; nil while in the background.
    private var foregroundSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var ended = false

    init(store: UsageStore, bucket: UsageGameBucket, scheme: TouchControlScheme,
         controllerConnected: Bool, orientation: UsageOrientation,
         center: NotificationCenter = .default,
         now: @escaping () -> Date = { .now }) {
        self.store = store
        self.bucket = bucket
        self.center = center
        self.now = now
        store.recordSessionStart(bucket: bucket, scheme: scheme,
                                 controllerConnected: controllerConnected,
                                 orientation: orientation, at: now())
        foregroundSince = now()
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                               object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterBackground() }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                               object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.willEnterForeground() }
            },
        ]
    }

    func didEnterBackground() {
        guard !ended, let since = foregroundSince else { return }
        foregroundSince = nil
        store.recordSessionBackgrounded(bucket: bucket,
                                        playTime: now().timeIntervalSince(since))
    }

    func willEnterForeground() {
        guard !ended, foregroundSince == nil else { return }
        foregroundSince = now()
        store.recordSessionForegrounded()
    }

    /// The engine returned. Only the foreground stretch still running is
    /// added: everything before it was saved at the last backgrounding.
    func end(exitCode: Int32) {
        guard !ended else { return }
        ended = true
        for observer in observers { center.removeObserver(observer) }
        observers = []
        let remaining = foregroundSince.map { now().timeIntervalSince($0) } ?? 0
        foregroundSince = nil
        store.recordSessionEnd(bucket: bucket, exitCode: exitCode,
                               playTime: remaining, at: now())
    }
}
