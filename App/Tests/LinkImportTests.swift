import Foundation
import SwiftData
import XCTest
import ZIPFoundation
@testable import Waddle

/// Answers every request from a table the test fills in, so no test here
/// touches the real network (#500).
final class StubURLProtocol: URLProtocol {
    enum Reply {
        /// A response, then the whole body, then the end.
        case respond(status: Int, headers: [String: String], body: Data)
        /// A transport failure before any response.
        case fail(URLError)
        /// A response and the first part of the body, then nothing: the
        /// download stays open until it is cancelled.
        case stall(headers: [String: String], firstChunk: Data)
        /// A 302 to another URL.
        case redirect(to: String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requested: [String] = []
    nonisolated(unsafe) private static var headers: [[String: String]] = []

    static func set(_ reply: Reply, for url: String) {
        lock.withLock { replies[url] = reply }
    }

    static func reset() {
        lock.withLock { replies = [:]; requested = []; headers = [] }
    }

    static var requestedURLs: [String] { lock.withLock { requested } }
    /// Each request's headers, as the session handed it to the protocol.
    static var requestHeaders: [[String: String]] { lock.withLock { headers } }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let key = request.url?.absoluteString ?? ""
        let reply: Reply? = Self.lock.withLock {
            Self.requested.append(key)
            Self.headers.append(request.allHTTPHeaderFields ?? [:])
            return Self.replies[key]
        }
        guard let reply, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch reply {
        case .respond(let status, let headers, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .stall(let headers, let firstChunk):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: firstChunk)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!),
                                redirectResponse: response)
        }
    }

    override func stopLoading() {}
}

@MainActor
final class LinkImportTests: XCTestCase {
    var library: LibraryService!
    var importer: ImportService!
    var notices: ImportNotices!
    var tmp: URL!
    var storeDir: URL!
    var downloadsDir: URL!

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        storeDir = tmp.appendingPathComponent("WADs", isDirectory: true)
        downloadsDir = tmp.appendingPathComponent("LinkDownloads", isDirectory: true)
        let store = WADStore(directory: storeDir)
        library = LibraryService(context: ModelContext(container), store: store)
        notices = ImportNotices()
        importer = ImportService(library: library, store: store, notices: notices,
                                 usage: UsageStore(directory: tmp.appendingPathComponent("Diagnostics",
                                                                                         isDirectory: true)))
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func linkImport(maxBytes: Int64 = LinkDownloader.maxBytes) -> LinkImport {
        var downloader = LinkDownloader()
        downloader.maxBytes = maxBytes
        downloader.directory = downloadsDir
        downloader.makeConfiguration = { StubURLProtocol.configuration() }
        return LinkImport(importer: importer, downloader: downloader, notices: notices)
    }

    /// Every regular file under `dir`, recursively; empty when `dir` is gone.
    private func files(under dir: URL) -> [String] {
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])
        else { return [] }
        return walker.compactMap { item -> String? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            return url.path
        }
    }

    private func assertNothingLeftBehind(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(files(under: downloadsDir), [], "a download left a file behind", file: file, line: line)
        XCTAssertEqual(files(under: storeDir), [], "the store holds a file", file: file, line: line)
        XCTAssertTrue(try library.allWADs().isEmpty, "the library registered a file", file: file, line: line)
    }

    // MARK: Downloads that import

    func testAnAttachmentIsImportedUnderTheServersName() async throws {
        let link = "https://files.example/download?id=42"
        StubURLProtocol.set(.respond(status: 200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Disposition": #"attachment; filename="map.wad""#,
        ], body: makeWAD(magic: "PWAD", lumps: ["MAP01"])), for: link)

        let outcome = await linkImport().run(URL(string: link)!)

        XCTAssertEqual(outcome?.imported, ["map"])
        XCTAssertEqual(outcome?.rejected, [:])
        XCTAssertEqual(try library.allWADs().first?.filename, "map.wad")
        XCTAssertEqual(notices.current, ImportNotices.summary(of: outcome ?? ImportOutcome()),
                       "the same banner a file picked in Files gets")
        XCTAssertEqual(files(under: downloadsDir), [], "the downloaded copy is removed once imported")
    }

    // MARK: Downloads that fail

    /// The usual result of a mirror's landing page: a 200 whose body is a
    /// web page. It is refused with a reason, and leaves nothing behind.
    func testAWebPageIsRejectedAndLeavesNothingBehind() async throws {
        let link = "https://mirror.example/maps/map.wad"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "text/html"],
                                     body: Data("\n<!doctype html><html><body>Download</body></html>".utf8)),
                            for: link)

        let outcome = await linkImport().run(URL(string: link)!)

        XCTAssertNil(outcome)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.webPage.reason)")
        try assertNothingLeftBehind()
    }

    func testA404AndAnOfflineFailureGiveDistinctReasons() async throws {
        let missing = "https://files.example/missing.wad"
        let offline = "https://files.example/offline.wad"
        StubURLProtocol.set(.respond(status: 404, headers: ["Content-Type": "text/html"],
                                     body: Data("<html>Not found</html>".utf8)), for: missing)
        StubURLProtocol.set(.fail(URLError(.notConnectedToInternet)), for: offline)

        let model = linkImport()
        let first = await model.run(URL(string: missing)!)
        XCTAssertNil(first)
        let notFound = notices.current
        XCTAssertEqual(notFound, "Import failed: \(LinkDownloadError.httpStatus(404).reason)")
        try assertNothingLeftBehind()

        let second = await model.run(URL(string: offline)!)
        XCTAssertNil(second)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.offline.reason)")
        XCTAssertNotEqual(notices.current, notFound)
        try assertNothingLeftBehind()
    }

    /// A `Content-Length` over the cap is refused from the response alone:
    /// not one body byte reaches the downloader.
    func testAContentLengthOverTheCapIsCancelledBeforeTheBodyIsRead() async throws {
        let link = "https://files.example/huge.zip"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Length": "4096"],
                                     body: Data(repeating: 0x50, count: 4096)), for: link)
        let bytesRead = LockedCounter()
        var downloader = LinkDownloader()
        downloader.maxBytes = 1024
        downloader.directory = downloadsDir
        downloader.makeConfiguration = { StubURLProtocol.configuration() }

        do {
            _ = try await downloader.download(URL(string: link)!) { received, _ in bytesRead.set(received) }
            XCTFail("an over-cap download completed")
        } catch let error as LinkDownloadError {
            XCTAssertEqual(error, .tooLarge(limit: 1024))
        }
        XCTAssertEqual(bytesRead.value, 0, "the body was read")
        try assertNothingLeftBehind()
    }

    /// With no `Content-Length` the cap still holds, on the bytes that arrive.
    func testABodyOverTheCapWithNoLengthIsRejected() async throws {
        let link = "https://files.example/chunked.wad"
        var body = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        body.append(Data(repeating: 0, count: 2048))
        StubURLProtocol.set(.respond(status: 200, headers: [:], body: body), for: link)

        let outcome = await linkImport(maxBytes: 1024).run(URL(string: link)!)
        XCTAssertNil(outcome)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.tooLarge(limit: 1024).reason)")
        try assertNothingLeftBehind()
    }

    func testACancelledDownloadLeavesNoFileAndNoNotice() async throws {
        let link = "https://files.example/slow.wad"
        // Typed, or URLSession holds this short chunk back to sniff its type
        // and the download never shows progress
        // (docs/learnings/urlsession-holds-back-a-short-untyped-chunk.md).
        let firstChunk = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        StubURLProtocol.set(.stall(headers: ["Content-Length": "100000",
                                            "Content-Type": "application/octet-stream"],
                                   firstChunk: firstChunk), for: link)
        let model = linkImport()

        let run = Task { await model.run(URL(string: link)!) }
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if case .downloading(let received, _) = model.phase, received > 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .downloading(let received, _) = model.phase, received > 0 else {
            return XCTFail("the download never started")
        }
        XCTAssertFalse(files(under: downloadsDir).isEmpty, "the partial file should exist mid-download")

        run.cancel()
        let outcome = await run.value

        XCTAssertNil(outcome)
        XCTAssertNil(notices.current, "a cancel the player asked for says nothing")
        XCTAssertEqual(model.phase, .idle)
        try assertNothingLeftBehind()
    }

    // MARK: Links that are never fetched

    func testAPlainHTTPLinkIsRefusedWithoutARequest() {
        let model = linkImport()
        XCTAssertFalse(model.start("http://files.example/map.wad"))
        XCTAssertEqual(model.invalidLink, LinkDownloadError.insecure.reason)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(StubURLProtocol.requestedURLs, [])
    }

    /// An https link that redirects to plain http is refused at the
    /// redirect, with the same reason as a typed http link, and the http
    /// URL is never requested.
    func testARedirectToHTTPIsRefused() async throws {
        let link = "https://files.example/map.wad"
        let insecure = "http://files.example/map.wad"
        StubURLProtocol.set(.redirect(to: insecure), for: link)
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                     body: makeWAD(magic: "PWAD", lumps: ["MAP01"])), for: insecure)

        let outcome = await linkImport().run(URL(string: link)!)

        XCTAssertNil(outcome)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.insecure.reason)")
        XCTAssertEqual(StubURLProtocol.requestedURLs, [link])
        try assertNothingLeftBehind()
    }

    // MARK: Review findings on #515

    /// A zip under a `.pk3` name is a mod, not a zip of WADs: refused with
    /// its own reason, not unpacked for its inner WAD.
    func testAPK3NamedByTheServerIsRefusedNotUnpacked() async throws {
        let link = "https://files.example/download?id=7"
        StubURLProtocol.set(.respond(status: 200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Disposition": #"attachment; filename="mod.pk3""#,
        ], body: try zipHoldingAWAD()), for: link)

        let outcome = await linkImport().run(URL(string: link)!)

        XCTAssertNil(outcome)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.refusedType("pk3").reason)")
        try assertNothingLeftBehind()
    }

    /// The link's own name counts too, whatever the server calls the file.
    func testAPK3NamedByTheLinkIsRefusedNotUnpacked() async throws {
        let link = "https://files.example/mods/mod.pk3"
        StubURLProtocol.set(.respond(status: 200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Disposition": #"attachment; filename="mod.zip""#,
        ], body: try zipHoldingAWAD()), for: link)

        let outcome = await linkImport().run(URL(string: link)!)

        XCTAssertNil(outcome)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.refusedType("pk3").reason)")
        try assertNothingLeftBehind()
    }

    /// Control characters in the server's name never reach the store or the
    /// banner.
    func testControlCharactersInTheServersNameAreDropped() async throws {
        let link = "https://files.example/download?id=8"
        StubURLProtocol.set(.respond(status: 200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Disposition": "attachment; filename*=UTF-8''ma%0Ap%07%E2%80%AE.wad",
        ], body: makeWAD(magic: "PWAD", lumps: ["MAP01"])), for: link)

        let outcome = await linkImport().run(URL(string: link)!)

        XCTAssertEqual(outcome?.imported, ["map"])
        XCTAssertEqual(try library.allWADs().first?.filename, "map.wad")
    }

    /// The sanitiser and the store's claimed names (#507) agree: a server
    /// name that sanitises to a filename another row still owns, with that
    /// row's file missing, is stored under a name of its own, and the other
    /// row is left without a file rather than given these bytes.
    func testASanitisedNameThatMatchesAClaimedNameGetsItsOwnFile() async throws {
        let claimant = try library.registerImported(filename: "map.wad", sha1: String(repeating: "a", count: 40),
                                                    kind: WADKind.pwad.rawValue, family: "doom2", hasMaps: true)
        XCTAssertEqual(library.fileStatus(for: claimant), .missing, "the claimant's file must be missing")
        let link = "https://files.example/download?id=10"
        StubURLProtocol.set(.respond(status: 200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Disposition": "attachment; filename*=UTF-8''ma%07p.wad",
        ], body: makeWAD(magic: "PWAD", lumps: ["MAP01"])), for: link)

        let outcome = await linkImport().run(URL(string: link)!)

        XCTAssertEqual(outcome?.imported, ["map (2)"])
        let row = try XCTUnwrap(try library.allWADs().first { $0.id != claimant.id })
        XCTAssertEqual(row.filename, "map (2).wad")
        XCTAssertEqual(library.fileStatus(for: row), .imported)
        XCTAssertEqual(claimant.filename, "map.wad")
        XCTAssertEqual(library.fileStatus(for: claimant), .missing,
                       "the claimant must not pick up a different file's bytes")
    }

    /// A name too long for the file system is shortened, extension kept,
    /// rather than failing the download.
    func testAnOverlongNameIsShortenedKeepingItsExtension() async throws {
        let link = "https://files.example/download?id=9"
        let long = String(repeating: "verylongname", count: 25) + ".wad"   // 304 bytes
        StubURLProtocol.set(.respond(status: 200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Disposition": "attachment; filename=\"\(long)\"",
        ], body: makeWAD(magic: "PWAD", lumps: ["MAP01"])), for: link)

        let outcome = await linkImport().run(URL(string: link)!)

        XCTAssertEqual(outcome?.imported.count, 1, "rejected: \(outcome?.rejected ?? [:]), notice: \(notices.current ?? "")")
        let stored = try XCTUnwrap(library.allWADs().first?.filename)
        XCTAssertTrue(stored.hasSuffix(".wad"), stored)
        XCTAssertTrue(stored.hasPrefix("verylongname"), stored)
        XCTAssertLessThanOrEqual(stored.utf8.count, ImportFilename.maxBytes)
    }

    /// What the request says about the player: a fixed User-Agent and no
    /// language preference, rather than the system's, and no cookies.
    func testTheRequestCarriesOnlyFixedHeaders() async throws {
        let link = "https://files.example/headers.wad"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/octet-stream"],
                                     body: makeWAD(magic: "PWAD", lumps: ["MAP01"])), for: link)

        _ = await linkImport().run(URL(string: link)!)

        let sent = try XCTUnwrap(StubURLProtocol.requestHeaders.first)
        XCTAssertEqual(sent["User-Agent"], "Waddle")
        XCTAssertEqual(sent["Accept-Language"], "*")
        XCTAssertNil(sent["Cookie"])
        let configuration = LinkDownloader.hardened(.ephemeral)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
    }

    /// A 200 that is neither a page nor a game file (an API's JSON error)
    /// gets a reason, as a web page does, not a bare "1 failed".
    func testAJSONBodyIsRejectedWithAReason() async throws {
        let link = "https://api.example/files/42"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "application/json"],
                                     body: Data(#"{"error":"rate limited"}"#.utf8)), for: link)

        let outcome = await linkImport().run(URL(string: link)!)

        XCTAssertNil(outcome)
        XCTAssertEqual(notices.current, "Import failed: \(LinkDownloadError.notAGameFile.reason)")
        try assertNothingLeftBehind()
    }

    private func zipHoldingAWAD() throws -> Data {
        let zipURL = tmp.appendingPathComponent(UUID().uuidString + ".zip")
        let archive = try Archive(url: zipURL, accessMode: .create)
        let wadData = makeWAD(magic: "PWAD", lumps: ["MAP01"])
        try archive.addEntry(with: "maps/MAP01.wad", type: .file, uncompressedSize: Int64(wadData.count),
                             provider: { pos, size in wadData.subdata(in: Int(pos)..<Int(pos) + size) })
        let data = try Data(contentsOf: zipURL)
        try FileManager.default.removeItem(at: zipURL)
        return data
    }

    func testValidation() {
        XCTAssertEqual(try LinkDownloader.validate("  https://files.example/map.wad\n").get(),
                       URL(string: "https://files.example/map.wad"))
        XCTAssertEqual(try LinkDownloader.validate("HTTPS://files.example/a.zip").get().host(), "files.example")
        XCTAssertEqual(LinkDownloader.validate("http://files.example/map.wad"), .failure(.insecure))
        XCTAssertEqual(LinkDownloader.validate(""), .failure(.notALink))
        XCTAssertEqual(LinkDownloader.validate("map.wad"), .failure(.notALink))
        XCTAssertEqual(LinkDownloader.validate("ftp://files.example/map.wad"), .failure(.notALink))
        XCTAssertEqual(LinkDownloader.validate("file:///etc/hosts"), .failure(.notALink))
    }

    func testTheCapIsTheZipEntryCap() {
        XCTAssertEqual(LinkDownloader.maxBytes, ZipExtractor.maxEntryBytes)
        XCTAssertEqual(LinkDownloader.maxBytes, 512 * 1024 * 1024)
    }
}

/// A value a `@Sendable` progress callback can write from the session's
/// queue and the test can read afterwards.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int64 = 0
    func set(_ value: Int64) { lock.withLock { stored = value } }
    var value: Int64 { lock.withLock { stored } }
}
