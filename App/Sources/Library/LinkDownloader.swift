import Foundation

/// Why a link the player gave could not be downloaded (#500). Every case but
/// cancellation ends in the import notice, so each `reason` says what the
/// player can do about it.
enum LinkDownloadError: Error, Equatable, Sendable {
    /// Not something a download can start from: empty, or no host.
    case notALink
    /// A plain `http` link, or an `https` one that redirects to `http`. The
    /// app has no App Transport Security exception and gets none.
    case insecure
    case offline
    /// The device is online but the server cannot be found or reached.
    case unreachable
    /// The server answered with something other than a 2xx status.
    case httpStatus(Int)
    /// The file is over `LinkDownloader.maxBytes`, by its `Content-Length`
    /// or by what actually arrived.
    case tooLarge(limit: Int64)
    /// The body is a web page: a mirror's landing page, not its file.
    case webPage
    /// Any other transport failure, with the system's own description.
    case failed(String)

    var reason: String {
        switch self {
        case .notALink:
            return "That is not a web link. Paste a link that starts with https://."
        case .insecure:
            return "Waddle only downloads secure links. Use the https:// version of the link."
        case .offline:
            return "You appear to be offline. Connect to the internet and try again."
        case .unreachable:
            return "Waddle could not reach the server. Check the link and try again."
        case .httpStatus(404):
            return "The server has no file at that link (error 404). Check the link and try again."
        case .httpStatus(let code):
            return "The server refused the download (error \(code)). Check the link, or try again later."
        case .tooLarge(let limit):
            return "The file is larger than the \(limit / (1024 * 1024)) MB import limit."
        case .webPage:
            return "That link opens a web page, not a file. Find the download link on the page and use that instead."
        case .failed(let description):
            return "The download failed: \(description)"
        }
    }
}

/// A finished download: the file, the name the server gave it, and the
/// directory the downloader made for it, which the caller removes once the
/// file has been imported.
struct DownloadedFile: Sendable {
    var url: URL
    var suggestedFilename: String
    var directory: URL
}

/// Fetches one `https` link the player gave to a local file, for
/// `ImportService.importFiles(_:from:)` (#500). It is the app's only network
/// code: it runs only when the player asks, sends nothing but the request for
/// that link, and keeps no cookies, cache or credentials (an ephemeral
/// session).
///
/// A download that fails for any reason, or is cancelled, leaves nothing
/// behind: the partial file and its directory are removed before the error
/// is thrown.
struct LinkDownloader: Sendable {
    /// The same cap as a zip entry, so a download is never refused for a
    /// size an unzipped file would be allowed.
    static let maxBytes: Int64 = ZipExtractor.maxEntryBytes

    var maxBytes: Int64 = LinkDownloader.maxBytes
    /// Where each download gets its own fresh directory. Outside Documents/,
    /// so the adoption scan never sees a partial file.
    var directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("LinkDownloads", isDirectory: true)
    /// Tests hand in a configuration whose `protocolClasses` stub the
    /// network; production uses a plain ephemeral one.
    var makeConfiguration: @Sendable () -> URLSessionConfiguration = { .ephemeral }

    /// The `https` URL `text` names, or why it names none. Surrounding
    /// whitespace is ignored, since a pasted link often carries some.
    static func validate(_ text: String) -> Result<URL, LinkDownloadError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host(), !host.isEmpty else {
            return .failure(.notALink)
        }
        switch scheme {
        case "https": return .success(url)
        case "http": return .failure(.insecure)
        default: return .failure(.notALink)
        }
    }

    /// Downloads `url`. `progress` is called with the bytes received so far
    /// and the expected total, when the server said; never before the first
    /// body bytes arrive. Throws `LinkDownloadError`, or `CancellationError`
    /// once the calling task is cancelled.
    func download(_ url: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> DownloadedFile {
        guard url.scheme?.lowercased() == "https" else { throw LinkDownloadError.insecure }
        let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let delegate = DownloadDelegate(directory: dir, maxBytes: maxBytes, progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: url)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }
}

/// The per-download session delegate. Every callback runs on the session's
/// serial delegate queue, and `start` hands it the continuation before the
/// task is resumed, so its state is only ever touched from one queue at a
/// time.
private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let directory: URL
    private let maxBytes: Int64
    private let progress: @Sendable (Int64, Int64?) -> Void

    private var continuation: CheckedContinuation<DownloadedFile, Error>?
    private var handle: FileHandle?
    private var fileURL: URL?
    private var suggestedFilename = "download"
    private var expected: Int64?
    private var received: Int64 = 0
    /// Whether the first non-whitespace body byte has been seen yet: it
    /// decides whether the body is a web page.
    private var sniffed = false
    /// Why this delegate cancelled the task itself, when it did.
    private var failure: LinkDownloadError?

    init(directory: URL, maxBytes: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.progress = progress
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<DownloadedFile, Error>) {
        self.continuation = continuation
        task.resume()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard request.url?.scheme?.lowercased() == "https" else {
            failure = .insecure
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        // A refused redirect hands its 3xx over as the response; keep the
        // reason it was refused for.
        if failure != nil {
            completionHandler(.cancel)
            return
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return refuse(.httpStatus(http.statusCode), completionHandler)
        }
        if response.expectedContentLength > maxBytes {
            return refuse(.tooLarge(limit: maxBytes), completionHandler)
        }
        expected = response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        suggestedFilename = Self.filename(for: response)
        let url = directory.appendingPathComponent(suggestedFilename)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            return refuse(.failed("Waddle could not save the file."), completionHandler)
        }
        self.fileURL = url
        self.handle = handle
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil, let handle else { return }
        if !sniffed, let first = data.first(where: { !Self.isWhitespace($0) }) {
            sniffed = true
            // A WAD starts "IWAD"/"PWAD", a zip "PK", a DeHackEd patch with
            // text; none of them with "<". An HTML page always does.
            if first == UInt8(ascii: "<") {
                failure = .webPage
                dataTask.cancel()
                return
            }
        }
        received += Int64(data.count)
        if received > maxBytes {
            failure = .tooLarge(limit: maxBytes)
            dataTask.cancel()
            return
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failure = .failed("Waddle could not save the file.")
            dataTask.cancel()
            return
        }
        progress(received, expected)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle?.close()
        handle = nil
        guard let continuation else { return }
        self.continuation = nil

        let result: Result<DownloadedFile, Error>
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(Self.map(error))
        } else if let fileURL {
            result = .success(DownloadedFile(url: fileURL, suggestedFilename: suggestedFilename,
                                             directory: directory))
        } else {
            result = .failure(LinkDownloadError.failed("The server sent no file."))
        }
        if case .failure = result {
            try? FileManager.default.removeItem(at: directory)
        }
        continuation.resume(with: result)
    }

    private func refuse(_ error: LinkDownloadError,
                        _ completionHandler: @Sendable (URLSession.ResponseDisposition) -> Void) {
        failure = error
        completionHandler(.cancel)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0xEF || byte == 0xBB || byte == 0xBF
    }

    /// The server's name for the file (`Content-Disposition`, else the
    /// link's last path component), reduced to one safe path component.
    static func filename(for response: URLResponse) -> String {
        let raw = response.suggestedFilename ?? ""
        let name = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.hasPrefix(".") ? "download" : name
    }

    private static func map(_ error: Error) -> Error {
        guard let urlError = error as? URLError else {
            return LinkDownloadError.failed(error.localizedDescription)
        }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed,
             .internationalRoamingOff:
            return LinkDownloadError.offline
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost, .timedOut:
            return LinkDownloadError.unreachable
        case .appTransportSecurityRequiresSecureConnection:
            return LinkDownloadError.insecure
        default:
            return LinkDownloadError.failed(urlError.localizedDescription)
        }
    }
}
