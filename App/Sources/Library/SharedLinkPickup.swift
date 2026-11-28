import Foundation
import UIKit

/// Links shared to Waddle from another app's share sheet (#551), picked up
/// when Waddle opens.
///
/// The share extension cannot open Waddle, so it leaves the link in
/// `PendingLinkInbox`, and Waddle picks it up at launch and on every return
/// to the foreground. From there it goes the way a link dropped on the
/// shelf goes (#550): checked again with `LinkDownloader.validate`, then
/// queued on the shelf's one `LinkImport`, so the player sees the same
/// progress, the same refusals and the same one notice when the queue ends.
///
/// Two rules keep a shared link from being lost or downloaded unseen (review
/// of pull request 561):
///
/// - **It waits until the shelf can show it.** A link is downloaded only
///   while the From a Link sheet can be presented to show its progress:
///   nothing else presented over the shelf (Settings, an alert, a game's
///   sheet) and no game session running. Until then it stays in the inbox,
///   and the pick-up looks again every `retryInterval`, only while links
///   are waiting. Started with a sheet already up, SwiftUI refused the From
///   a Link sheet ("only presenting a single sheet"), the download ran
///   anyway, and its notice expired under the open sheet.
/// - **It leaves the inbox only once its result was shown.** A link stays
///   in its file while it downloads and is removed when the queue it joined
///   has ended -- added, refused with a reason, or cancelled by the player.
///   A link whose download the app never finished (killed, or crashed) is
///   picked up again the next time. Within one run, a link already queued
///   is not queued twice.
@MainActor
final class SharedLinkPickup {
    /// Queues `urls`, with `extras` for the batch's notice, and calls the
    /// completion once the queue they joined has ended: `LinkImport.enqueue`.
    typealias Enqueue = (_ urls: [URL], _ extras: LinkImport.Extras,
                         _ onFinish: @escaping @MainActor () -> Void) -> Void

    private let inbox: () -> PendingLinkInbox?
    private let canPresent: () -> Bool
    private let retryInterval: Duration
    /// The files of links queued in this run and not yet ended.
    private(set) var inFlight: Set<URL> = []
    private var waiter: Task<Void, Never>?

    init(inbox: @escaping () -> PendingLinkInbox? = { .shared() },
         canPresent: @escaping () -> Bool,
         retryInterval: Duration = .seconds(1)) {
        self.inbox = inbox
        self.canPresent = canPresent
        self.retryInterval = retryInterval
    }

    /// Whether a pick-up is waiting for the shelf to be clear.
    var isWaiting: Bool { waiter != nil }

    /// Picks up the waiting links as soon as the shelf can show them: now,
    /// or, while something is in the way, once it is not. `onStarted` runs
    /// when something is to be downloaded, for the shelf to open its sheet.
    func pickUpWhenClear(into enqueue: @escaping Enqueue, onStarted: @escaping @MainActor () -> Void) {
        guard waiter == nil, hasWaitingLinks else { return }
        if pickUp(into: enqueue, onStarted: onStarted) != nil { return }
        waiter = Task { [weak self, retryInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: retryInterval)
                guard let self, self.hasWaitingLinks else { break }
                if self.pickUp(into: enqueue, onStarted: onStarted) != nil { break }
            }
            self?.waiter = nil
        }
    }

    /// One attempt: nil when the shelf cannot show a download now (and
    /// nothing is taken), else whether anything is to be downloaded. Up to
    /// `WADDrop.maxLinksPerDrop` links not already queued, oldest first, go
    /// to `enqueue` in one call: those to download, and in the extras any
    /// refused, for the notice to name.
    @discardableResult
    func pickUp(into enqueue: Enqueue, onStarted: @MainActor () -> Void = {}) -> Bool? {
        guard canPresent() else { return nil }
        guard let inbox = inbox() else { return false }
        let items = inbox.waiting().filter { !inFlight.contains($0.file) }.prefix(WADDrop.maxLinksPerDrop)
        guard !items.isEmpty else { return false }
        var downloads: [URL] = []
        var extras = LinkImport.Extras()
        for item in items {
            // The extension already refused a link Waddle would refuse; this
            // is the same second check a dropped link gets, against a file
            // the app did not write itself.
            switch LinkDownloader.validate(item.url.absoluteString) {
            case .success(let url): downloads.append(url)
            case .failure(let error): extras.refused.append((item.url, error))
            }
        }
        let taken = Array(items)
        let files = Set(taken.map(\.file))
        inFlight.formUnion(files)
        enqueue(downloads, extras) { [weak self] in
            inbox.remove(taken)
            self?.inFlight.subtract(files)
        }
        if !downloads.isEmpty { onStarted() }
        return !downloads.isEmpty
    }

    private var hasWaitingLinks: Bool {
        guard let inbox = inbox() else { return false }
        return inbox.waiting().contains { !inFlight.contains($0.file) }
    }

    /// Whether the shelf can show a shared link's download now: the app is
    /// active, no game session is running, and nothing is presented over
    /// the shelf's window. Each of these, false, held a link back.
    static func shelfCanPresent(engineRunning: Bool = EngineSession.isRunning,
                                appActive: Bool = UIApplication.shared.applicationState == .active,
                                root: UIViewController? = keyRootViewController()) -> Bool {
        guard !engineRunning, appActive, let root else { return false }
        return !presentsAnything(root)
    }

    /// Whether `controller`, or any controller it contains, is presenting
    /// another: a sheet, an alert or a dialog, wherever in the view tree
    /// SwiftUI presented it from.
    static func presentsAnything(_ controller: UIViewController) -> Bool {
        controller.presentedViewController != nil || controller.children.contains { presentsAnything($0) }
    }

    /// The root view controller of the active scene's key window.
    static func keyRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}
