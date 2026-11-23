import Foundation
import Observation

/// One link import at a time (#500): validate the player's link, download it
/// with `LinkDownloader`, then hand the file and the server's name for it to
/// `ImportService.importFiles(_:from:)`, so it ends in the same banner and
/// outcome as a file picked in Files. A download that fails ends in the same
/// banner too, with the reason; a cancelled one ends silently, as a closed
/// picker does. Either way nothing is left behind.
@MainActor
@Observable
final class LinkImport {
    enum Phase: Equatable {
        case idle
        /// Bytes so far, and the total when the server said.
        case downloading(received: Int64, expected: Int64?)
        case importing
    }

    private(set) var phase: Phase = .idle
    /// Why the link in the field cannot be downloaded at all (not https,
    /// not a link). Shown in the sheet, which stays open for a fix.
    private(set) var invalidLink: String?

    private let importer: ImportService
    private let downloader: LinkDownloader
    private let notices: ImportNotices
    private var task: Task<Void, Never>?

    var isBusy: Bool { phase != .idle }

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
            task = Task {
                await run(url)
                onFinish()
            }
            return true
        }
    }

    func cancel() {
        task?.cancel()
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
