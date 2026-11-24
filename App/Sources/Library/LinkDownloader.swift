import CryptoKit
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
    /// The file is named as a type Waddle refuses (a `.pk3`), by the
    /// server's filename or the link's.
    case refusedType(String)
    /// The body is neither a web page nor anything Waddle takes: an API's
    /// JSON error, say, or a text file.
    case notAGameFile
    /// The file arrived whole but is not the one a source pins (#502): its
    /// SHA-256 differs from the one the app ships for that link.
    case checksumMismatch
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
        case .refusedType(let ext):
            return "That link leads to a .\(ext) file, which Waddle does not take. Waddle takes .wad, .deh, .bex and .zip files."
        case .notAGameFile:
            return "That link did not lead to a game file. Waddle takes .wad, .deh, .bex and .zip files; check that the link is to the file itself."
        case .checksumMismatch:
            return "The file at that link is not the one Waddle expects, so it was not added. Try again later."
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
/// session). The request carries only the headers `requestHeaders` fixes and
/// the ones HTTP itself needs (Host, Accept, Accept-Encoding); PRIVACY.md
/// lists exactly what is sent, so change both together.
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

    /// Replaces what the system would send: its User-Agent names the app's
    /// build, CFNetwork and Darwin versions (so the iOS version), and its
    /// Accept-Language lists the player's languages. Neither is needed to
    /// download a file.
    static let requestHeaders: [String: String] = [
        "User-Agent": "Waddle",
        "Accept-Language": "*",
    ]

    /// `configuration` with nothing kept and nothing extra sent: no cookies
    /// stored or sent, no cache, no credentials, and `requestHeaders`.
    static func hardened(_ configuration: URLSessionConfiguration) -> URLSessionConfiguration {
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = requestHeaders
        return configuration
    }

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
    /// body bytes arrive. With `expectedSHA256` (lowercase hex, a source's
    /// pin, #502), a whole download whose bytes hash to anything else fails
    /// with `.checksumMismatch` and is removed. Throws `LinkDownloadError`,
    /// or `CancellationError` once the calling task is cancelled.
    func download(_ url: URL, expectedSHA256: String? = nil,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> DownloadedFile {
        guard url.scheme?.lowercased() == "https" else { throw LinkDownloadError.insecure }
        let dir = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let delegate = DownloadDelegate(directory: dir, maxBytes: maxBytes,
                                        expectedSHA256: expectedSHA256?.lowercased(), progress: progress)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Self.hardened(makeConfiguration()),
                                 delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        // Set on the request as well as the session: a request's own value
        // wins over whatever the system would add.
        var request = URLRequest(url: url)
        for (field, value) in Self.requestHeaders { request.setValue(value, forHTTPHeaderField: field) }
        let task = session.dataTask(with: request)

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
    private let expectedSHA256: String?
    private let progress: @Sendable (Int64, Int64?) -> Void
    /// Every body byte written so far, hashed as it arrives, so a pinned
    /// download is checked without reading the file a second time.
    private var hasher = SHA256()

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

    init(directory: URL, maxBytes: Int64, expectedSHA256: String?,
         progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.expectedSHA256 = expectedSHA256
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
            hasher.update(data: data)
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
        } else if let expectedSHA256, Self.hex(hasher.finalize()) != expectedSHA256 {
            result = .failure(LinkDownloadError.checksumMismatch)
        } else if let fileURL {
            result = Self.check(fileURL, named: suggestedFilename, linkURL: task.currentRequest?.url)
                .map { DownloadedFile(url: fileURL, suggestedFilename: suggestedFilename, directory: directory) }
                .mapError { $0 as Error }
        } else {
            result = .failure(LinkDownloadError.failed("The server sent no file."))
        }
        if case .failure = result {
            try? FileManager.default.removeItem(at: directory)
        }
        continuation.resume(with: result)
    }

    /// Whether a whole download is something the importer takes, so a body
    /// it would refuse fails here with a reason the notice can show, rather
    /// than as a bare "1 failed". The same rule the importer applies
    /// (`ImportFileType.resolve`), so the two cannot disagree.
    static func check(_ file: URL, named name: String, linkURL: URL?) -> Result<Void, LinkDownloadError> {
        for candidate in [(name as NSString).pathExtension, linkURL?.pathExtension ?? ""] {
            let ext = candidate.lowercased()
            if ImportFileType.refusedExtensions.contains(ext) { return .failure(.refusedType(ext)) }
        }
        return ImportFileType.resolve(url: file, name: name) == nil ? .failure(.notAGameFile) : .success(())
    }

    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
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
    /// link's last path component), made safe by `ImportFilename`.
    static func filename(for response: URLResponse) -> String {
        ImportFilename.sanitized(response.suggestedFilename ?? "")
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
