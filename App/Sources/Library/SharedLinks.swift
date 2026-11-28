import Foundation

/// Links shared to Waddle from another app's share sheet (#551), picked up
/// when Waddle opens.
///
/// The share extension cannot open Waddle, so it leaves the link in
/// `PendingLinkInbox` and Waddle takes it at launch and on every return to
/// the foreground. From there it goes the way a link dropped on the shelf
/// goes (#550): checked again with `LinkDownloader.validate`, then queued on
/// the shelf's one `LinkImport`, so the player sees the same progress, the
/// same refusals and the same one notice when the queue ends. Nothing about
/// a shared link is downloaded or decided differently.
enum SharedLinks {
    /// Takes up to `WADDrop.maxLinksPerDrop` links from `inbox`, oldest
    /// first, and hands them to `enqueue` in one call: those to download,
    /// and, in the extras, any refused, for the notice to name. Any over the
    /// cap wait for the next pick-up. Returns whether anything is to be
    /// downloaded; nothing is handed over when the inbox is empty.
    @MainActor
    @discardableResult
    static func pickUp(from inbox: PendingLinkInbox?,
                       into enqueue: ([URL], LinkImport.Extras) -> Void) -> Bool {
        guard let inbox else { return false }
        let taken = inbox.take(limit: WADDrop.maxLinksPerDrop)
        guard !taken.isEmpty else { return false }
        var downloads: [URL] = []
        var extras = LinkImport.Extras()
        for url in taken {
            // The extension already refused a link Waddle would refuse; this
            // is the same second check a dropped link gets, against a file
            // the app did not write itself.
            switch LinkDownloader.validate(url.absoluteString) {
            case .success(let url): downloads.append(url)
            case .failure(let error): extras.refused.append((url, error))
            }
        }
        enqueue(downloads, extras)
        return !downloads.isEmpty
    }
}
