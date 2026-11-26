import SwiftData
import UniformTypeIdentifiers
import XCTest
@testable import Waddle

/// The shelf's drop handler (#481): a dropped file must end exactly as the
/// same file picked with the picker does, in the same outcome and the same
/// banner. Each test imports through the drop handler into one library and
/// through the picker into a second, independent one, and compares.
@MainActor
final class WADDropTests: XCTestCase {
    private var tmp: URL!

    private struct Stack {
        let library: LibraryService
        let importer: ImportService
        let notices: ImportNotices
    }

    override func setUpWithError() throws {
        StubURLProtocol.reset()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeStack() throws -> Stack {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: WADFile.self, Game.self, configurations: config)
        let store = WADStore(directory: tmp.appendingPathComponent(UUID().uuidString, isDirectory: true))
        let library = LibraryService(context: ModelContext(container), store: store)
        library.bundledContentDirectory = try FreedoomFixture.directory()
        let notices = ImportNotices()
        let usage = UsageStore(directory: tmp.appendingPathComponent(UUID().uuidString, isDirectory: true))
        return Stack(library: library,
                     importer: ImportService(library: library, store: store, notices: notices, usage: usage),
                     notices: notices)
    }

    private func write(_ name: String, _ data: Data) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Drops `urls` on one fresh library and picks them in another, and
    /// returns both outcomes and both banners.
    private func dropAndPick(_ urls: [URL]) async throws
        -> (dropped: ImportOutcome, picked: ImportOutcome, dropBanner: String?, pickBanner: String?, dropStack: Stack) {
        let dropStack = try makeStack()
        let pickStack = try makeStack()
        let dropped = await WADDrop.importDropped(urls, into: dropStack.importer)
        let picked = await pickStack.importer.importFiles(at: urls, from: .picker)
        return (dropped, picked, dropStack.notices.current, pickStack.notices.current, dropStack)
    }

    func testADroppedWADIsImported() async throws {
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))

        let result = try await dropAndPick([wad])

        XCTAssertEqual(result.dropped.imported, ["sunlust"])
        XCTAssertTrue(result.dropped.rejected.isEmpty)
        XCTAssertEqual(try result.dropStack.library.allWADs().filter { !$0.isBundled }.map(\.kindRaw),
                       [WADKind.pwad.rawValue])
        XCTAssertEqual(result.dropped, result.picked)
        XCTAssertNotNil(result.dropBanner)
        XCTAssertEqual(result.dropBanner, result.pickBanner)
    }

    func testAnUnsupportedFileIsRejectedWithThePickerPathsNotice() async throws {
        let text = try write("readme.txt", Data("not a game".utf8))

        let result = try await dropAndPick([text])

        XCTAssertTrue(result.dropped.imported.isEmpty)
        XCTAssertEqual(result.dropped.rejected, ["readme.txt": "Unsupported file type."])
        XCTAssertEqual(result.dropped, result.picked)
        XCTAssertNotNil(result.dropBanner)
        XCTAssertEqual(result.dropBanner, result.pickBanner)
        // Like the picker, a drop leaves a rejected file where it was: the
        // player still has it, and it is not the library's to move.
        XCTAssertFalse(ImportRoute.drop.quarantinesRejects)
        XCTAssertTrue(FileManager.default.fileExists(atPath: text.path))
        XCTAssertFalse(result.dropBanner?.contains("Import Failed") ?? true)
    }

    func testSeveralFilesAreHandledInOneDrop() async throws {
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let deh = try write("patch.deh", Data("Patch File for DeHackEd v3.0\n".utf8))
        let pk3 = try write("mod.pk3", Data("PK\u{3}\u{4}".utf8))

        let result = try await dropAndPick([wad, deh, pk3])

        XCTAssertEqual(Set(result.dropped.imported), ["sunlust", "patch"])
        XCTAssertEqual(result.dropped.rejected, ["mod.pk3": ImportFileType.refusedReason])
        XCTAssertEqual(result.dropped, result.picked)
        // One banner for the whole drop, the one the picker gives for the
        // same three files.
        XCTAssertNotNil(result.dropBanner)
        XCTAssertEqual(result.dropBanner, result.pickBanner)
    }

    /// The system takes its copy of a dropped file back as soon as it hands
    /// it over, so `stage` keeps one of its own under the same name, and the
    /// handler removes it once imported.
    func testAStagedCopyKeepsItsNameAndIsRemovedOnceImported() async throws {
        let original = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let staged = try WADDrop.stage(original)
        try FileManager.default.removeItem(at: original)

        XCTAssertEqual(staged.lastPathComponent, "sunlust.wad")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))

        let stack = try makeStack()
        let outcome = await WADDrop.importDropped([staged], into: stack.importer)

        XCTAssertEqual(outcome.imported, ["sunlust"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
    }

    /// A URL the handler did not stage is the caller's, and stays.
    func testAFileOutsideTheStagingFolderIsLeftInPlace() async throws {
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let stack = try makeStack()

        _ = await WADDrop.importDropped([wad], into: stack.importer)

        XCTAssertTrue(FileManager.default.fileExists(atPath: wad.path))
    }

    // MARK: DroppedFile: reading a dropped item out of its provider

    private var wadType: UTType { UTType("com.tylervick.waddle.wad")! }

    /// A provider that offers only `type` content, handing over `handedOver`
    /// (no `public.file-url`), as a source other than Files or Finder may.
    private func contentOnlyProvider(_ handedOver: URL, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(for: type, visibility: .all, openInPlace: false) { completion in
            completion(handedOver, false, nil)
            return nil
        }
        return provider
    }

    /// Files and Finder offer a dragged file by its URL. Without a
    /// `suggestedName` the copy handed over is named after the type, so the
    /// name must come from the URL.
    func testADroppedFileTakesItsNameFromItsURLWithoutASuggestedName() async throws {
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: wad))
        provider.suggestedName = nil

        let request = await DroppedFile.request(for: provider)

        XCTAssertEqual(request.url.lastPathComponent, "sunlust.wad")
        XCTAssertEqual(try Data(contentsOf: request.url), try Data(contentsOf: wad))
        let outcome = await WADDrop.importDropped([request], into: try makeStack().importer)
        XCTAssertEqual(outcome.imported, ["sunlust"])
    }

    func testADroppedFileWithNoURLTakesItsSuggestedName() async throws {
        let handedOver = try write("tmp-4F1C", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let provider = contentOnlyProvider(handedOver, type: wadType)
        provider.suggestedName = "sunlust"

        let request = await DroppedFile.request(for: provider)

        XCTAssertEqual(request.url.lastPathComponent, "sunlust.wad")
        let outcome = await WADDrop.importDropped([request], into: try makeStack().importer)
        XCTAssertEqual(outcome.imported, ["sunlust"])
    }

    /// With neither, the copy's own name is all there is; it still gets its
    /// type's extension, so the import knows what it is.
    func testADroppedFileWithNeitherIsNamedAfterTheCopyWithItsTypesExtension() async throws {
        let handedOver = try write("tmp-4F1C", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let provider = contentOnlyProvider(handedOver, type: wadType)
        provider.suggestedName = nil

        let request = await DroppedFile.request(for: provider)

        XCTAssertEqual(request.url.pathExtension, "wad")
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.url.path))
        let outcome = await WADDrop.importDropped([request], into: try makeStack().importer)
        XCTAssertEqual(outcome.imported.count, 1)
        XCTAssertTrue(outcome.rejected.isEmpty)
    }

    /// The order the name is taken in, with what a provider hands over
    /// standing in as the system names it: after the type, "Doom WAD.wad".
    /// (The provider tests above cannot show the second and third steps on
    /// their own, because the system's copy already follows
    /// `suggestedName` and already carries the extension.)
    func testTheNameComesFromTheURLThenTheSuggestedNameThenTheCopy() {
        let original = URL(fileURLWithPath: "/Users/someone/Downloads/sunlust.wad")
        let copy = URL(fileURLWithPath: "/tmp/x/Doom WAD.wad")
        XCTAssertEqual(DroppedFile.filename(fileURL: original, suggestedName: "other",
                                            handedOver: copy, type: wadType), "sunlust.wad")
        XCTAssertEqual(DroppedFile.filename(fileURL: nil, suggestedName: "sunlust",
                                            handedOver: copy, type: wadType), "sunlust.wad")
        XCTAssertEqual(DroppedFile.filename(fileURL: nil, suggestedName: nil,
                                            handedOver: copy, type: wadType), "Doom WAD.wad")
    }

    func testANameWithNoExtensionGetsItsTypesAndNoNameAtAllGetsAPlaceholder() {
        XCTAssertEqual(DroppedFile.filename(fileURL: nil, suggestedName: nil,
                                            handedOver: URL(fileURLWithPath: "/tmp/x/tmp-4F1C"),
                                            type: .zip), "tmp-4F1C.zip")
        XCTAssertEqual(DroppedFile.filename(fileURL: nil, suggestedName: " ", handedOver: nil, type: nil),
                       "Dropped item")
    }

    func testTheNameIsSanitised() {
        let name = DroppedFile.filename(fileURL: nil, suggestedName: "../evil\nname", handedOver: nil, type: wadType)
        XCTAssertEqual(name, ImportFilename.sanitized("../evil\nname.wad"))
        XCTAssertFalse(name.contains("/"))
    }

    /// A folder matches only through `public.file-url`. It is refused as an
    /// unsupported type under its own name, and no plist of its URL is
    /// staged as though it were a file.
    func testADroppedFolderIsRefusedByNameWithoutStagingItsURL() async throws {
        let folder = tmp.appendingPathComponent("Maps", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: folder))

        let request = await DroppedFile.request(for: provider)

        XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.path))
        let outcome = await WADDrop.importDropped([request], into: try makeStack().importer)
        XCTAssertEqual(outcome.rejected, ["Maps": "Unsupported file type."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    /// A `.pk3` is a type the app does not declare, so it too matches only
    /// by URL; it gets the reason every other route gives a pk3.
    func testADroppedPK3IsRefusedWithThePK3Reason() async throws {
        let pk3 = try write("mod.pk3", Data([0x50, 0x4B, 0x03, 0x04]))
        let provider = try XCTUnwrap(NSItemProvider(contentsOf: pk3))
        provider.suggestedName = nil

        let request = await DroppedFile.request(for: provider)

        XCTAssertFalse(FileManager.default.fileExists(atPath: request.url.path))
        let outcome = await WADDrop.importDropped([request], into: try makeStack().importer)
        XCTAssertEqual(outcome.rejected, ["mod.pk3": ImportFileType.refusedReason])
    }

    /// A text snippet is not a file, so the shelf does not light up for it;
    /// a web link it takes, as a link (#550).
    func testTheShelfDoesNotTakeTextAndTakesAnHTTPSLink() {
        XCTAssertFalse(WADDrop.acceptedTypes.contains(.data))
        let text = NSItemProvider(object: "hello" as NSString)
        for provider in [text] {
            XCTAssertFalse(WADDrop.acceptedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) },
                           "\(provider.registeredTypeIdentifiers)")
        }
        let link = linkProvider("https://example.com/x.wad")
        XCTAssertTrue(accepted(link), "\(link.registeredTypeIdentifiers)")
        XCTAssertTrue(DroppedLink.isLink(link))
    }

    // MARK: Dropped links (#550)

    /// A provider built the way WebKit builds a link drag: an `NSURL` and
    /// an `NSString` of the same URL, and no `suggestedName`.
    private func linkProvider(_ link: String,
                              make: (NSURL) -> NSItemProvider = { NSItemProvider(object: $0) }) -> NSItemProvider {
        let provider = make(URL(string: link)! as NSURL)
        provider.registerObject(link as NSString, visibility: .all)
        provider.suggestedName = nil
        return provider
    }

    /// Whether the shelf's `onDrop` would deliver `provider` at all.
    private func accepted(_ provider: NSItemProvider) -> Bool {
        WADDrop.acceptedTypes.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
    }

    private var downloadsDir: URL { tmp.appendingPathComponent("LinkDownloads", isDirectory: true) }

    /// The shelf's link download over `stack`, with the network stubbed.
    private func linkImport(for stack: Stack) -> LinkImport {
        var downloader = LinkDownloader()
        downloader.directory = downloadsDir
        downloader.makeConfiguration = { StubURLProtocol.configuration() }
        return LinkImport(importer: stack.importer, downloader: downloader, notices: stack.notices)
    }

    private func serveWAD(at link: String, named name: String, lumps: [String] = ["MAP01"]) {
        StubURLProtocol.set(.respond(status: 200, headers: [
            "Content-Type": "application/octet-stream",
            "Content-Disposition": #"attachment; filename="\#(name)""#,
        ], body: makeWAD(magic: "PWAD", lumps: lumps)), for: link)
    }

    /// Drops `providers` on the shelf, as its `onDrop` would deliver them,
    /// and waits for every file to be imported and every link to end.
    /// Returns the files' outcome, if the drop had files.
    @discardableResult
    private func drop(_ providers: [NSItemProvider], on stack: Stack, links: LinkImport,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> ImportOutcome? {
        for provider in providers {
            XCTAssertTrue(accepted(provider), "the shelf would not take \(provider.registeredTypeIdentifiers)",
                          file: file, line: line)
        }
        let hasFiles = providers.contains { !DroppedLink.isLink($0) }
        let hasLinks = providers.contains { DroppedLink.isLink($0) }
        var outcome: ImportOutcome?
        let filesDone = hasFiles ? expectation(description: "the files' outcome") : nil
        let linksStarted = hasLinks ? expectation(description: "the links queued") : nil
        XCTAssertTrue(WADDrop.handleDrop(providers, into: stack.importer, links: links,
                                         onLinkDownloadsStarted: { linksStarted?.fulfill() }) {
            outcome = $0
            filesDone?.fulfill()
        }, file: file, line: line)
        let expectations = [filesDone, linksStarted].compactMap { $0 }
        await fulfillment(of: expectations, timeout: 20)
        let deadline = Date().addingTimeInterval(20)
        while links.isBusy, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(links.isBusy, "the link downloads never ended", file: file, line: line)
        return outcome
    }

    func testAnHTTPSLinkIsDownloadedAndImportedUnderTheServersName() async throws {
        let link = "https://files.example/download?id=42"
        serveWAD(at: link, named: "map.wad")
        let stack = try makeStack()

        try await drop([linkProvider(link)], on: stack, links: linkImport(for: stack))

        XCTAssertEqual(StubURLProtocol.requestedURLs, [link])
        XCTAssertEqual(try stack.library.allWADs().filter { !$0.isBundled }.map(\.filename), ["map.wad"])
        // The banner the same file gets picked in Files, as From a Link…
        // gives it.
        let picked = try makeStack()
        let same = try write("map.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        _ = await picked.importer.importFiles(at: [same], from: .picker)
        XCTAssertNotNil(stack.notices.current)
        XCTAssertEqual(stack.notices.current, picked.notices.current)
        XCTAssertTrue(files(under: downloadsDir).isEmpty, "the downloaded copy is removed once imported")
    }

    func testAnHTTPLinkIsRefusedAndNothingIsFetched() async throws {
        let stack = try makeStack()

        try await drop([linkProvider("http://files.example/map.wad")], on: stack, links: linkImport(for: stack))

        XCTAssertEqual(StubURLProtocol.requestedURLs, [])
        XCTAssertEqual(stack.notices.current, "Import failed: \(LinkDownloadError.insecure.reason)")
        XCTAssertTrue(try stack.library.allWADs().filter { !$0.isBundled }.isEmpty)
    }

    func testALinkThatIsNotAWebLinkIsRefusedAsNotALink() async throws {
        for link in ["ftp://files.example/map.wad", "mailto:someone@example.com"] {
            StubURLProtocol.reset()
            let stack = try makeStack()

            try await drop([linkProvider(link)], on: stack, links: linkImport(for: stack))

            XCTAssertEqual(StubURLProtocol.requestedURLs, [], link)
            XCTAssertEqual(stack.notices.current, "Import failed: \(LinkDownloadError.notALink.reason)", link)
        }
    }

    /// The most common drop: a link to a page, not a file.
    func testALinkToAPageIsRefusedAsAWebPageWithNothingStored() async throws {
        let link = "https://github.com/freedoom/freedoom/releases"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "text/html"],
                                     body: Data("<html><body>Releases</body></html>".utf8)), for: link)
        let stack = try makeStack()

        try await drop([linkProvider(link)], on: stack, links: linkImport(for: stack))

        XCTAssertEqual(stack.notices.current, "Import failed: \(LinkDownloadError.webPage.reason)")
        XCTAssertTrue(try stack.library.allWADs().filter { !$0.isBundled }.isEmpty)
        XCTAssertTrue(files(under: downloadsDir).isEmpty)
    }

    /// Plain text is not a link: the shelf does not light up for it.
    func testPlainTextAloneIsNotTaken() {
        let text = NSItemProvider(object: "sunlust.wad from the forum" as NSString)
        XCTAssertFalse(accepted(text), "\(text.registeredTypeIdentifiers)")
        XCTAssertFalse(DroppedLink.isLink(text))
    }

    /// Text that is itself an `https` URL is offered as `public.url` too,
    /// by `NSString` (from Notes, say), so it is taken as the link it is.
    func testTextThatIsAnHTTPSURLIsTakenAsALink() async throws {
        let link = "https://files.example/text.wad"
        serveWAD(at: link, named: "text.wad")
        let text = NSItemProvider(object: link as NSString)
        let stack = try makeStack()

        try await drop([text], on: stack, links: linkImport(for: stack))

        XCTAssertEqual(StubURLProtocol.requestedURLs, [link])
        XCTAssertEqual(try stack.library.allWADs().filter { !$0.isBundled }.map(\.filename), ["text.wad"])
    }

    func testSeveralLinksAreDownloadedInTheOrderDropped() async throws {
        let links = ["https://files.example/c", "https://files.example/a", "https://files.example/b"]
        for (index, link) in links.enumerated() {
            serveWAD(at: link, named: "\(link.suffix(1)).wad", lumps: ["MAP0\(index + 1)"])
        }
        let stack = try makeStack()

        try await drop(links.map { linkProvider($0) }, on: stack, links: linkImport(for: stack))

        XCTAssertEqual(StubURLProtocol.requestedURLs, links)
        XCTAssertEqual(Set(try stack.library.allWADs().filter { !$0.isBundled }.map(\.filename)),
                       ["c.wad", "a.wad", "b.wad"])
    }

    func testElevenLinksDownloadTenAndRefuseOneInOneNotice() async throws {
        let links = (1...11).map { "https://files.example/\($0)" }
        for (index, link) in links.enumerated() {
            serveWAD(at: link, named: "map\(index + 1).wad", lumps: ["MAP\(String(format: "%02d", index + 1))"])
        }
        let stack = try makeStack()

        try await drop(links.map { linkProvider($0) }, on: stack, links: linkImport(for: stack))

        XCTAssertEqual(WADDrop.maxLinksPerDrop, 10)
        XCTAssertEqual(StubURLProtocol.requestedURLs, Array(links.prefix(10)))
        XCTAssertEqual(try stack.library.allWADs().filter { !$0.isBundled }.count, 10)
        XCTAssertEqual(stack.notices.current, WADDrop.tooManyLinksNotice(extra: 1))
        XCTAssertEqual(WADDrop.tooManyLinksNotice(extra: 1),
                       "Drop up to 10 links at a time. 1 link was not downloaded.")
    }

    func testAFileAndALinkInOneDropAreBothImported() async throws {
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let fileProvider = try XCTUnwrap(NSItemProvider(contentsOf: wad))
        fileProvider.suggestedName = nil
        let link = "https://files.example/download?id=7"
        serveWAD(at: link, named: "map.wad", lumps: ["MAP02"])
        let stack = try makeStack()

        let outcome = try await drop([fileProvider, linkProvider(link)], on: stack, links: linkImport(for: stack))

        XCTAssertEqual(outcome?.imported, ["sunlust"])
        XCTAssertFalse(DroppedLink.isLink(fileProvider), "a file goes the file's way")
        XCTAssertEqual(StubURLProtocol.requestedURLs, [link])
        XCTAssertEqual(Set(try stack.library.allWADs().filter { !$0.isBundled }.map(\.filename)),
                       ["sunlust.wad", "map.wad"])
    }

    /// As for files: a drag from another process may end once the handler
    /// returns, so a link's URL is asked for before it does.
    func testEveryLinksLoadIsRequestedBeforeTheDropHandlerReturns() async throws {
        let recorder = LoadRecorder()
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let file = try XCTUnwrap(RecordingProvider(contentsOf: wad))
        file.name = "file"
        file.recorder = recorder
        let link = "https://files.example/map.wad"
        serveWAD(at: link, named: "map.wad", lumps: ["MAP02"])
        let linkItem = try XCTUnwrap(linkProvider(link) { RecordingProvider(object: $0) } as? RecordingProvider)
        linkItem.name = "link"
        linkItem.recorder = recorder
        let stack = try makeStack()
        let links = linkImport(for: stack)
        let started = expectation(description: "the link queued")
        let done = expectation(description: "the file's outcome")

        let accepted = WADDrop.handleDrop([file, linkItem], into: stack.importer, links: links,
                                          onLinkDownloadsStarted: { started.fulfill() }) { _ in done.fulfill() }
        recorder.handlerReturned = true

        XCTAssertTrue(accepted)
        // The file's URL and content, and the link's URL.
        XCTAssertEqual(recorder.requests.sorted(), ["file", "file", "link"])
        await fulfillment(of: [started, done], timeout: 10)
        XCTAssertTrue(recorder.lateRequests.isEmpty, "requested after the handler returned: \(recorder.lateRequests)")
    }

    /// Every regular file under `dir`; empty when `dir` is gone.
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
    // MARK: Every load is requested before the drop handler returns

    /// A drag from another process may end once the drop handler returns,
    /// and a load first requested after that can fail. So the handler starts
    /// every provider's loads itself, and only awaits them afterwards.
    func testEveryLoadIsRequestedBeforeTheDropHandlerReturns() async throws {
        let recorder = LoadRecorder()
        var providers: [NSItemProvider] = []
        for (index, name) in ["c-first", "a-second", "b-third"].enumerated() {
            let wad = try write("\(name).wad", makeWAD(magic: "PWAD", lumps: ["MAP0\(index + 1)"]))
            let provider = try XCTUnwrap(RecordingProvider(contentsOf: wad))
            provider.name = name
            provider.recorder = recorder
            providers.append(provider)
        }
        let stack = try makeStack()
        let done = expectation(description: "the drop's outcome")
        var outcome: ImportOutcome?

        let accepted = WADDrop.handleDrop(providers, into: stack.importer) {
            outcome = $0
            done.fulfill()
        }
        recorder.handlerReturned = true

        XCTAssertTrue(accepted)
        // Both loads -- the URL and the content -- of all three.
        XCTAssertEqual(recorder.requests.sorted(),
                       ["a-second", "a-second", "b-third", "b-third", "c-first", "c-first"])
        await fulfillment(of: [done], timeout: 10)
        XCTAssertTrue(recorder.lateRequests.isEmpty, "requested after the handler returned: \(recorder.lateRequests)")
        // In the order they were dropped.
        XCTAssertEqual(outcome?.imported, ["c-first", "a-second", "b-third"])
    }
}

/// What `RecordingProvider`s saw: each load request, by provider, and any
/// made after the drop handler returned.
private final class LoadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _handlerReturned = false
    private(set) var requests: [String] = []
    private(set) var lateRequests: [String] = []

    var handlerReturned: Bool {
        get { lock.withLock { _handlerReturned } }
        set { lock.withLock { _handlerReturned = newValue } }
    }

    func record(_ name: String) {
        lock.withLock {
            if _handlerReturned { lateRequests.append(name) } else { requests.append(name) }
        }
    }
}

/// A Files-style provider (`init(contentsOf:)`) that records when each load
/// is asked for.
private final class RecordingProvider: NSItemProvider, @unchecked Sendable {
    var name = ""
    var recorder: LoadRecorder?

    override func loadFileRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (URL?, (any Error)?) -> Void
    ) -> Progress {
        recorder?.record(name)
        return super.loadFileRepresentation(forTypeIdentifier: typeIdentifier,
                                            completionHandler: completionHandler)
    }

    override func loadObject(
        ofClass aClass: any NSItemProviderReading.Type,
        completionHandler: @escaping @Sendable ((any NSItemProviderReading)?, (any Error)?) -> Void
    ) -> Progress {
        recorder?.record(name)
        return super.loadObject(ofClass: aClass, completionHandler: completionHandler)
    }
}
