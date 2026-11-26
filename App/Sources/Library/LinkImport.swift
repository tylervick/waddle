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
/// order they were added. Cancel stops the one downloading and drops the
/// rest. The shelf owns the one instance, so the sheet shows the progress of
/// a download it did not start.
///
/// The notice is one string, and the sheet covers it while the queue runs,
/// so a batch of more than one link -- or a drop that also carried files,
/// refused links, or more links than it may -- is reported once, as a
/// whole, when the queue empties: `ImportNotices.summary` of everything the
/// batch added, with its first failure's reason and "N more failed"
/// (#521's convention), and the links over the cap. A single link keeps
/// its own notice.
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

    /// What a drop hands over besides the links to download: the outcome of
    /// the files it carried, the links refused before any download (a plain
    /// `http` link), and how many links it carried over the cap. All of it
    /// is told in the batch's one notice.
    struct Extras {
        var files: ImportOutcome?
        var refused: [(url: URL, error: LinkDownloadError)] = []
        var overCap = 0

        var isEmpty: Bool { files == nil && refused.isEmpty && overCap == 0 }
    }

    /// How one link ended.
    enum LinkResult {
        case imported(ImportOutcome)
        case failed(LinkDownloadError)
        case cancelled
    }

    private(set) var phase: Phase = .idle
    /// Why the link in the field cannot be downloaded at all (not https,
    /// not a link). Shown in the sheet, which stays open for a fix. Cleared
    /// once a download starts and when the sheet closes (`clearInvalidLink`),
    /// since the one instance outlives the sheet.
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
    /// Which queue run is current. A cancelled run winds down after `cancel`
    /// has returned; it must not clear what a later `enqueue` started.
    private var generation = 0
    private var pending: [URL] = []
    private var queued = 0
    private var finishers: [@MainActor () -> Void] = []
    /// The batch so far: every link's outcome, folded together.
    private var batch = ImportOutcome()
    private var batchOverCap = 0
    /// Whether the batch is more than one link on its own, and so is told
    /// as a whole.
    private var batchIsCompound = false

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
            enqueue([url], onFinish: onFinish)
            return true
        }
    }

    /// Forgets the field's refusal: for the sheet to call as it closes.
    func clearInvalidLink() {
        invalidLink = nil
    }

    /// Queues `urls` -- each already one `LinkDownloader.validate` accepts --
    /// to download after any already queued, in order, and starts on them
    /// unless a download is running. `extras` joins the batch's one notice.
    /// `onFinish` runs once the queue has emptied. With no links, nothing
    /// is downloaded: `extras` is told at once, or with the running batch.
    func enqueue(_ urls: [URL], extras: Extras = Extras(),
                 onFinish: @escaping @MainActor () -> Void = {}) {
        if let files = extras.files { batch.merge(files) }
        for refusal in extras.refused {
            batch.merge(Self.failure(of: refusal.url, refusal.error))
        }
        batchOverCap += extras.overCap
        if !extras.isEmpty || queued + urls.count > 1 { batchIsCompound = true }
        guard !urls.isEmpty else {
            if task == nil { tellBatch(); resetBatch() }
            return onFinish()
        }
        invalidLink = nil
        pending += urls
        queued += urls.count
        finishers.append(onFinish)
        guard task == nil else { return }
        isBusy = true
        generation += 1
        let run = generation
        task = Task { await drain(run) }
    }

    /// Stops the download running now and drops every link still queued.
    /// What the batch had already done is still told. The queue is over at
    /// once: a link queued from here on starts a run of its own, which the
    /// cancelled one, still winding down, does not touch.
    func cancel() {
        guard let task else { return }
        task.cancel()
        finish()
    }

    private func drain(_ run: Int) async {
        var index = 0
        while !pending.isEmpty, !Task.isCancelled {
            let url = pending.removeFirst()
            index += 1
            current = url
            position = Position(index: index, count: queued)
            let result = await download(url)
            guard run == generation else { return }
            switch result {
            case .imported(let outcome): batch.merge(outcome)
            case .failed(let error):
                if !batchIsCompound { notices.post(message: "Import failed: \(error.reason)") }
                batch.merge(Self.failure(of: url, error))
            case .cancelled: break
            }
        }
        guard run == generation else { return }
        finish()
    }

    /// Ends the queue: tells the batch, clears it, and runs the finishers.
    private func finish() {
        generation += 1
        task = nil
        tellBatch()
        resetBatch()
        pending = []
        queued = 0
        current = nil
        position = nil
        isBusy = false
        let done = finishers
        finishers = []
        for finish in done { finish() }
    }

    /// Posts the batch's one notice, if it is told as a whole. A lone link
    /// has already said how it ended.
    private func tellBatch() {
        guard batchIsCompound else { return }
        let parts = [ImportNotices.summary(of: batch),
                     batchOverCap > 0 ? WADDrop.tooManyLinksNotice(extra: batchOverCap) : nil].compactMap { $0 }
        if !parts.isEmpty { notices.post(message: parts.joined(separator: " · ")) }
    }

    private func resetBatch() {
        batch = ImportOutcome()
        batchOverCap = 0
        batchIsCompound = false
    }

    /// A link's failure, as an outcome that names it, for the batch.
    nonisolated static func failure(of url: URL, _ error: LinkDownloadError) -> ImportOutcome {
        var outcome = ImportOutcome()
        outcome.reject(displayName(of: url), reason: error.reason, explained: true)
        return outcome
    }

    /// What a link is called in the notice: its last path component, or its
    /// host for a link to a site's root.
    nonisolated static func displayName(of url: URL) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host() ?? url.absoluteString
    }

    /// Downloads and imports `url`. The import's outcome, or nil when the
    /// download failed (the notice then says why) or was cancelled.
    @discardableResult
    func run(_ url: URL) async -> ImportOutcome? {
        switch await download(url) {
        case .imported(let outcome): return outcome
        case .failed(let error):
            notices.post(message: "Import failed: \(error.reason)")
            return nil
        case .cancelled: return nil
        }
    }

    /// Downloads and imports `url`, and says how it ended; posts nothing of
    /// its own but the import's notice.
    private func download(_ url: URL) async -> LinkResult {
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
            return .failed(error)
        } catch {
            // Cancelled: the player asked for it, so there is nothing to say.
            return .cancelled
        }
        defer { try? FileManager.default.removeItem(at: file.directory) }
        // Past this point the file is whole: it is imported even if the
        // player cancels now, as a picked file would be.
        phase = .importing
        return .imported(await Task { [importer] in
            await importer.importFiles([ImportRequest(url: file.url, suggestedFilename: file.suggestedFilename)],
                                       from: .link)
        }.value)
    }
}
