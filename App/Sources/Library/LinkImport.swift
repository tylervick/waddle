import Foundation
import Observation

/// One link import at a time (#500): validate the player's link, download it
/// with `LinkDownloader`, then hand the file and the server's name for it to
/// `ImportService.importFiles(_:from:)`, so it ends in the same banner and
/// outcome as a file picked in Files. A download that fails ends in the same
/// banner too, with the reason; a cancelled one ends silently, as a closed
/// picker does. Either way nothing is left behind.
///
/// Links queue: the sheet's field adds one, and a drop on the shelf adds
/// every link it carried (#550), which download one after another in the
/// order they were added, each ending in its own notice. Cancel stops the
/// one downloading and drops the rest. The shelf owns the one instance, so
/// the sheet shows the progress of a download it did not start.
@MainActor
@Observable
final class LinkImport {
    enum Phase: Equatable {
        case idle
        /// Bytes so far, and the total when the server said.
        case downloading(received: Int64, expected: Int64?)
        case importing
    }

    /// Where the link downloading now stands among those queued with it:
    /// "1 of 3". Counts every link added since the queue was last empty.
    struct Position: Equatable {
        var index: Int
        var count: Int
    }

    private(set) var phase: Phase = .idle
    /// Why the link in the field cannot be downloaded at all (not https,
    /// not a link). Shown in the sheet, which stays open for a fix.
    private(set) var invalidLink: String?
    /// The link downloading now, and its place in the queue; nil when idle.
    private(set) var current: URL?
    private(set) var position: Position?
    /// True from the first queued link until the last has ended.
    private(set) var isBusy = false

    private let importer: ImportService
    private let downloader: LinkDownloader
    private let notices: ImportNotices
    private var task: Task<Void, Never>?
    private var pending: [URL] = []
    private var queued = 0
    private var finishers: [@MainActor () -> Void] = []

    init(importer: ImportService, downloader: LinkDownloader = LinkDownloader(),
         notices: ImportNotices? = nil) {
        self.importer = importer
        self.downloader = downloader
        self.notices = notices ?? .shared
    }

    /// Starts importing `text`'s link unless it is not one Waddle downloads,
    /// in which case `invalidLink` says why. Returns whether it started;
    /// `onFinish` runs once a started import has ended, however it ended.
    @discardableResult
    func start(_ text: String, onFinish: @escaping @MainActor () -> Void = {}) -> Bool {
        guard !isBusy else { return false }
        switch LinkDownloader.validate(text) {
        case .failure(let error):
            invalidLink = error.reason
            return false
        case .success(let url):
            invalidLink = nil
            enqueue([url], onFinish: onFinish)
            return true
        }
    }

    /// Queues `urls` to download after any already queued, in order, and
    /// starts on them unless a download is running. Each is checked as the
    /// field's link is: one Waddle does not download is refused in the
    /// notice, with the same reason, when its turn comes, and nothing is
    /// fetched for it. `onFinish` runs once the queue has emptied.
    func enqueue(_ urls: [URL], onFinish: @escaping @MainActor () -> Void = {}) {
        guard !urls.isEmpty else { return onFinish() }
        pending += urls
        queued += urls.count
        finishers.append(onFinish)
        guard task == nil else { return }
        isBusy = true
        task = Task { await drain() }
    }

    /// Posts `message` in the import notice: for a refusal about the links
    /// themselves, such as a drop that carried too many.
    func post(_ message: String) {
        notices.post(message: message)
    }

    /// Stops the download running now and drops every link still queued.
    func cancel() {
        pending = []
        task?.cancel()
    }

    private func drain() async {
        var index = 0
        while !pending.isEmpty, !Task.isCancelled {
            let url = pending.removeFirst()
            index += 1
            current = url
            position = Position(index: index, count: queued)
            switch LinkDownloader.validate(url.absoluteString) {
            case .failure(let error):
                notices.post(message: "Import failed: \(error.reason)")
            case .success(let url):
                await run(url)
            }
        }
        pending = []
        queued = 0
        current = nil
        position = nil
        task = nil
        isBusy = false
        let done = finishers
        finishers = []
        for finish in done { finish() }
    }

    /// Downloads and imports `url`. The import's outcome, or nil when the
    /// download failed (the notice then says why) or was cancelled.
    @discardableResult
    func run(_ url: URL) async -> ImportOutcome? {
        phase = .downloading(received: 0, expected: nil)
        defer { phase = .idle }
        let file: DownloadedFile
        do {
            file = try await downloader.download(url) { received, expected in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(received: received, expected: expected)
                }
            }
        } catch let error as LinkDownloadError {
            notices.post(message: "Import failed: \(error.reason)")
            return nil
        } catch {
            // Cancelled: the player asked for it, so there is nothing to say.
            return nil
        }
        defer { try? FileManager.default.removeItem(at: file.directory) }
        // Past this point the file is whole: it is imported even if the
        // player cancels now, as a picked file would be.
        phase = .importing
        return await Task { [importer] in
            await importer.importFiles([ImportRequest(url: file.url, suggestedFilename: file.suggestedFilename)],
                                       from: .link)
        }.value
    }
}
