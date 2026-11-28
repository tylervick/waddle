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
///
/// The Get Freedoom tile's download (#552) is one more link in the same
/// queue, pinned to the release's SHA-256, with its own notice wording and
/// a callback with how it ended. It starts only on an empty queue, so it
/// never runs beside the sheet's link or a drop's; a drop arriving while it
/// downloads queues behind it, as behind any link, and Cancel is the
/// queue's.
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
    /// Which queued entry is downloading now, nil when idle. The Get Freedoom
    /// tile owns only the entry it started, whatever its link: the same
    /// release link pasted into From a Link… is an ordinary download.
    private(set) var currentEntry: UUID?
    private(set) var position: Position?
    /// True from the first queued link until the last has ended.
    private(set) var isBusy = false
    /// Why the last link to fail did, until the next one starts.
    private(set) var lastFailure: LinkDownloadError?

    private let importer: ImportService
    private let downloader: LinkDownloader
    private let notices: ImportNotices
    private var task: Task<Void, Never>?
    /// Which queue run is current. A cancelled run winds down after `cancel`
    /// has returned; it must not clear what a later `enqueue` started.
    private var generation = 0
    /// A link waiting its turn: most are only a URL; the Get Freedoom
    /// tile's carries its pin, its notice wording and a callback.
    private struct Entry {
        let id = UUID()
        var url: URL
        var expectedSHA256: String?
        var failureMessage: (@MainActor (LinkDownloadError) -> String)?
        var onEnd: (@MainActor (LinkResult) -> Void)?
    }

    private var pending: [Entry] = []
    private var queued = 0
    private var finishers: [@MainActor () -> Void] = []
    /// Tests only: awaited once a download is whole, before it is imported,
    /// so a test can hold a link at `.importing`.
    @ObservationIgnored var beforeImport: (@MainActor () async -> Void)?
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

    /// Starts the Get Freedoom tile's download (#552): `url`, refusing any
    /// bytes whose SHA-256 is not `expectedSHA256`, with a failure's notice
    /// in `failureMessage`'s words (the player followed no link). Only on an
    /// empty queue; returns the entry's identity, which `currentEntry`
    /// shows while it downloads, or nil when it did not start. `onEnd` runs
    /// once, with how it ended: `.cancelled` when the queue was cancelled
    /// under it.
    @discardableResult
    func start(_ url: URL, expectedSHA256: String,
               failureMessage: @escaping @MainActor (LinkDownloadError) -> String,
               onEnd: @escaping @MainActor (LinkResult) -> Void) -> UUID? {
        guard !isBusy else { return nil }
        let ended = Once(onEnd)
        let entry = Entry(url: url, expectedSHA256: expectedSHA256, failureMessage: failureMessage,
                          onEnd: { ended.call($0) })
        start([entry], onFinish: { ended.call(.cancelled) })
        return entry.id
    }

    /// Calls its closure the first time only.
    @MainActor
    private final class Once {
        private var body: (@MainActor (LinkResult) -> Void)?
        init(_ body: @escaping @MainActor (LinkResult) -> Void) { self.body = body }
        func call(_ result: LinkResult) {
            let run = body
            body = nil
            run?(result)
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
        start(urls.map { Entry(url: $0) }, onFinish: onFinish)
    }

    /// Queues `entries` and starts the queue unless it is running.
    private func start(_ entries: [Entry], onFinish: @escaping @MainActor () -> Void) {
        pending += entries
        queued += entries.count
        finishers.append(onFinish)
        guard task == nil else { return }
        // The first link is the current one from now, not from when the
        // queue's task first runs: the tile asks whose download this is.
        current = pending.first?.url
        currentEntry = pending.first?.id
        isBusy = true
        generation += 1
        let run = generation
        task = Task { await drain(run) }
    }

    /// Stops the download running now and drops every link still queued.
    /// What the batch had already done is still told. The queue is over at
    /// once: a link queued from here on starts a run of its own, which the
    /// cancelled one, still winding down, does not touch.
    ///
    /// A link already being added to the library cannot be stopped, as a
    /// picked file cannot: Cancel then drops only the links still queued,
    /// and the queue ends once that import has, so the drop's one notice
    /// counts it and is not replaced by the import's own (re-review of pull
    /// request 555).
    func cancel() {
        guard let task else { return }
        pending = []
        if phase == .importing { return }
        task.cancel()
        finish()
    }

    private func drain(_ run: Int) async {
        var index = 0
        while !pending.isEmpty, !Task.isCancelled {
            let entry = pending.removeFirst()
            let url = entry.url
            index += 1
            current = url
            currentEntry = entry.id
            position = Position(index: index, count: queued)
            lastFailure = nil
            let result = await download(url, expectedSHA256: entry.expectedSHA256, run: run)
            guard run == generation else { return }
            switch result {
            case .imported(let outcome): batch.merge(outcome)
            case .failed(let error):
                lastFailure = error
                if !batchIsCompound {
                    notices.post(message: entry.failureMessage?(error) ?? "Import failed: \(error.reason)")
                }
                // In a batch told as a whole (a link dropped behind the
                // tile's), the tile's entry keeps its own words there too.
                batch.merge(entry.failureMessage.map { Self.failure(named: "Freedoom", message: $0(error)) }
                            ?? Self.failure(of: url, error))
            case .cancelled: break
            }
            entry.onEnd?(result)
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
        currentEntry = nil
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

    /// A failure told in its own whole words, for an entry that has them.
    nonisolated static func failure(named name: String, message: String) -> ImportOutcome {
        var outcome = ImportOutcome()
        outcome.rejected[name] = message
        outcome.explained.append(message)
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
        switch await download(url, expectedSHA256: nil, run: nil) {
        case .imported(let outcome): return outcome
        case .failed(let error):
            lastFailure = error
            notices.post(message: "Import failed: \(error.reason)")
            return nil
        case .cancelled: return nil
        }
    }

    /// Whether `run` (nil: a lone `run(_:)`) is still the queue's.
    private func isCurrent(_ run: Int?) -> Bool {
        run == nil || run == generation
    }

    /// Downloads and imports `url`, and says how it ended; posts nothing of
    /// its own but the import's notice.
    ///
    /// `run` is the queue run it belongs to, nil for a lone `run(_:)`. Once a
    /// cancel has ended that run, `phase` is a later run's, and this leaves
    /// it alone: a cancelled download winds down after a link queued
    /// straight after the cancel has started (re-review of pull request 555).
    private func download(_ url: URL, expectedSHA256: String?, run: Int?) async -> LinkResult {
        phase = .downloading(received: 0, expected: nil)
        defer { if isCurrent(run) { phase = .idle } }
        let file: DownloadedFile
        do {
            file = try await downloader.download(url, expectedSHA256: expectedSHA256) { received, expected in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(run), case .downloading = self.phase else { return }
                    self.phase = .downloading(received: received, expected: expected)
                }
            }
        } catch let error as LinkDownloadError {
            return .failed(error)
        } catch is CancellationError {
            // Cancelled: the player asked for it, so there is nothing to say.
            return .cancelled
        } catch {
            // Anything else is a failure, however rare (the downloads
            // folder could not be made, say): said, with its reason, never
            // passed off as a cancel.
            return .failed(.failed(error.localizedDescription))
        }
        defer { try? FileManager.default.removeItem(at: file.directory) }
        // Past this point the file is whole: it is imported even if the
        // player cancels now, as a picked file would be.
        if isCurrent(run) { phase = .importing }
        await beforeImport?()
        return .imported(await Task { [importer] in
            await importer.importFiles([ImportRequest(url: file.url, suggestedFilename: file.suggestedFilename)],
                                       from: .link)
        }.value)
    }
}
