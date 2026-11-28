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

    /// What a drop did: the files' outcome, if it had files, and whether it
    /// asked the shelf to open From a Link… on its downloads.
    private struct DropResult {
        var files: ImportOutcome?
        var openedTheSheet = false
    }

    /// Drops `providers` on the shelf, as its `onDrop` would deliver them,
    /// and waits for every file to be imported and every link to end.
    @discardableResult
    private func drop(_ providers: [NSItemProvider], on stack: Stack, links: LinkImport,
                      file: StaticString = #filePath, line: UInt = #line) async throws -> DropResult {
        for provider in providers {
            XCTAssertTrue(accepted(provider), "the shelf would not take \(provider.registeredTypeIdentifiers)",
                          file: file, line: line)
        }
        var result = DropResult()
        let handled = expectation(description: "the drop handled")
        XCTAssertTrue(WADDrop.handleDrop(providers, into: stack.importer, links: links,
                                         onLinkDownloadsStarted: { result.openedTheSheet = true },
                                         onHandled: { handled.fulfill() }) { result.files = $0 },
                      file: file, line: line)
        await fulfillment(of: [handled], timeout: 20)
        let deadline = Date().addingTimeInterval(20)
        while links.isBusy, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(links.isBusy, "the link downloads never ended", file: file, line: line)
        return result
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

    /// Refused by the drop itself, before anything is queued: so the sheet
    /// does not flash open and shut for it, and the stub sees no request.
    /// (`LinkDownloader.download`'s own guard would refuse it too, but only
    /// once queued, with the sheet open: this test fails without the drop's
    /// check.)
    func testAnHTTPLinkIsRefusedWithoutOpeningTheSheetAndNothingIsFetched() async throws {
        let stack = try makeStack()

        let result = try await drop([linkProvider("http://files.example/map.wad")], on: stack,
                                    links: linkImport(for: stack))

        XCTAssertFalse(result.openedTheSheet)
        XCTAssertEqual(StubURLProtocol.requestedURLs, [])
        XCTAssertEqual(stack.notices.current,
                       "Import failed for map.wad: \(LinkDownloadError.insecure.reason)")
        XCTAssertTrue(try stack.library.allWADs().filter { !$0.isBundled }.isEmpty)
    }

    /// `NSString` offers any text it parses as a URL as `public.url`, "Note:
    /// hi" included, so the shelf lights up for it and nothing can be read
    /// until the drop. The drop then lets it go: no notice, no sheet, no
    /// request. The same for a scheme that is not http(s).
    func testTextOrALinkThatIsNotAWebLinkIsLetGoQuietly() async throws {
        let texts = ["Note: hi", "Tip:use-warp", "javascript:alert(1)"]
        let links = ["ftp://files.example/map.wad", "mailto:someone@example.com", "https:no-host"]
        let providers = texts.map { NSItemProvider(object: $0 as NSString) } + links.map { linkProvider($0) }
        for provider in providers {
            StubURLProtocol.reset()
            let stack = try makeStack()

            let result = try await drop([provider], on: stack, links: linkImport(for: stack))

            let what = "\(provider.registeredTypeIdentifiers)"
            XCTAssertFalse(result.openedTheSheet, what)
            XCTAssertEqual(StubURLProtocol.requestedURLs, [], what)
            XCTAssertNil(stack.notices.current, what)
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
        // Told once, as a whole.
        let notice = try XCTUnwrap(stack.notices.current)
        for name in ["c", "a", "b"] {
            XCTAssertTrue(notice.contains(name), notice)
        }
    }

    /// One notice for the whole drop, in #521's form: what it added, the
    /// first failure's reason, and "N more failed". No link's result is lost
    /// under the next one's.
    func testAMixedDropIsToldOnceAsAWhole() async throws {
        let good = "https://files.example/good"
        serveWAD(at: good, named: "good.wad")
        let page = "https://files.example/releases"
        StubURLProtocol.set(.respond(status: 200, headers: ["Content-Type": "text/html"],
                                     body: Data("<html></html>".utf8)), for: page)
        let stack = try makeStack()

        let result = try await drop([linkProvider("http://files.example/x.wad"), linkProvider(good),
                                     linkProvider(page)], on: stack, links: linkImport(for: stack))

        XCTAssertTrue(result.openedTheSheet)
        XCTAssertEqual(StubURLProtocol.requestedURLs, [good, page])
        let notice = try XCTUnwrap(stack.notices.current)
        XCTAssertTrue(notice.contains("good"), notice)
        XCTAssertTrue(notice.contains("Import failed for x.wad: \(LinkDownloadError.insecure.reason)"), notice)
        XCTAssertTrue(notice.hasSuffix("1 more failed"), notice)
        XCTAssertEqual(try stack.library.allWADs().filter { !$0.isBundled }.map(\.filename), ["good.wad"])
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
        // The cap is part of the drop's one notice, after what the ten did,
        // not a notice of its own over the tenth link's result.
        let notice = try XCTUnwrap(stack.notices.current)
        XCTAssertTrue(notice.hasSuffix(" · " + WADDrop.tooManyLinksNotice(extra: 1)), notice)
        XCTAssertTrue(notice.contains("map10"), notice)
        XCTAssertEqual(WADDrop.tooManyLinksNotice(extra: 1),
                       "1 more link was not taken: drop up to 10 links at a time")
    }

    func testAFileAndALinkInOneDropAreBothImported() async throws {
        let wad = try write("sunlust.wad", makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let fileProvider = try XCTUnwrap(NSItemProvider(contentsOf: wad))
        fileProvider.suggestedName = nil
        let link = "https://files.example/download?id=7"
        serveWAD(at: link, named: "map.wad", lumps: ["MAP02"])
        let stack = try makeStack()

        let outcome = try await drop([fileProvider, linkProvider(link)], on: stack,
                                     links: linkImport(for: stack)).files

        XCTAssertEqual(outcome?.imported, ["sunlust"])
        XCTAssertFalse(DroppedLink.isLink(fileProvider), "a file goes the file's way")
        XCTAssertEqual(StubURLProtocol.requestedURLs, [link])
        XCTAssertEqual(Set(try stack.library.allWADs().filter { !$0.isBundled }.map(\.filename)),
                       ["sunlust.wad", "map.wad"])
        // One notice for the drop, the file's import included.
        let notice = try XCTUnwrap(stack.notices.current)
        XCTAssertTrue(notice.contains("sunlust") && notice.contains("map"), notice)
    }

    // MARK: The shared link download (review of pull request 555)

    /// The field's refusal belongs to that one try: it is gone once a
    /// download starts (a drop, say) and once the sheet closes.
    func testTheFieldsRefusalIsClearedByADownloadAndByClosingTheSheet() async throws {
        let stack = try makeStack()
        let links = linkImport(for: stack)

        XCTAssertFalse(links.start("http://files.example/a.wad"))
        XCTAssertEqual(links.invalidLink, LinkDownloadError.insecure.reason)
        links.clearInvalidLink()
        XCTAssertNil(links.invalidLink, "closing the sheet")

        XCTAssertFalse(links.start("http://files.example/a.wad"))
        let link = "https://files.example/b"
        serveWAD(at: link, named: "b.wad")
        var refusalWhileDownloading: String?? = .none
        let handled = expectation(description: "the drop handled")
        WADDrop.handleDrop([linkProvider(link)], into: stack.importer, links: links,
                           onLinkDownloadsStarted: { refusalWhileDownloading = .some(links.invalidLink) },
                           onHandled: { handled.fulfill() }) { _ in }
        await fulfillment(of: [handled], timeout: 10)
        XCTAssertEqual(refusalWhileDownloading, .some(nil), "a dropped link's download shows no old refusal")
    }

    /// What the player sees of a link queued straight after a cancel: its
    /// own download's progress, not the "Adding to your library…" the
    /// cancelled download's cleanup would leave behind (re-review of pull
    /// request 555).
    func testALinkQueuedJustAfterACancelShowsItsOwnProgress() async throws {
        let stall: StubURLProtocol.Reply = .stall(headers: ["Content-Length": "100000",
                                                            "Content-Type": "application/octet-stream"],
                                                  firstChunk: makeWAD(magic: "PWAD", lumps: ["MAP01"]))
        let slow = "https://files.example/slow.wad"
        let next = "https://files.example/next.wad"
        StubURLProtocol.set(stall, for: slow)
        StubURLProtocol.set(stall, for: next)
        let stack = try makeStack()
        let links = linkImport(for: stack)

        links.enqueue([URL(string: slow)!])
        let deadline = Date().addingTimeInterval(10)
        while StubURLProtocol.requestedURLs.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        links.cancel()
        links.enqueue([URL(string: next)!])
        while StubURLProtocol.requestedURLs.count < 2, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Long enough for the cancelled download to have wound down.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(links.current, URL(string: next))
        XCTAssertEqual(links.position, LinkImport.Position(index: 1, count: 1))
        guard case .downloading(let received, let expected) = links.phase else {
            links.cancel()
            return XCTFail("the new link shows \(links.phase), not its download")
        }
        XCTAssertGreaterThan(received, 0, "its progress is shown")
        XCTAssertEqual(expected, 100_000)
        links.cancel()
    }

    /// Cancel while a link is being added to the library: the import cannot
    /// be stopped, so it finishes, and the drop's one notice -- which counts
    /// it -- is the one left standing, not the import's own.
    func testCancelWhileImportingLeavesTheDropsNotice() async throws {
        let first = "https://files.example/first"
        let second = "https://files.example/second"
        serveWAD(at: first, named: "first.wad")
        serveWAD(at: second, named: "second.wad", lumps: ["MAP02"])
        let stack = try makeStack()
        let links = linkImport(for: stack)
        let importing = expectation(description: "the first link is being imported")
        var release: CheckedContinuation<Void, Never>?
        links.beforeImport = {
            links.beforeImport = nil
            await withCheckedContinuation { continuation in
                release = continuation
                importing.fulfill()
            }
        }
        var extras = LinkImport.Extras()
        extras.refused = [(URL(string: "http://files.example/x.wad")!, .insecure)]

        links.enqueue([URL(string: first)!, URL(string: second)!], extras: extras)
        await fulfillment(of: [importing], timeout: 10)
        XCTAssertEqual(links.phase, .importing)
        links.cancel()
        release?.resume()
        let deadline = Date().addingTimeInterval(10)
        while links.isBusy || links.phase != .idle, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // Let anything the cancelled run still had to say arrive.
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(StubURLProtocol.requestedURLs, [first], "the second link was cancelled")
        XCTAssertEqual(try stack.library.allWADs().filter { !$0.isBundled }.map(\.filename), ["first.wad"])
        let notice = try XCTUnwrap(stack.notices.current)
        XCTAssertTrue(notice.contains("first"), notice)
        XCTAssertTrue(notice.contains("Import failed for x.wad"), "the drop's notice, not the import's: \(notice)")
    }

    /// A link queued while a cancelled download is still winding down is
    /// downloaded, not dropped with the cancelled queue.
    func testALinkQueuedJustAfterACancelIsDownloaded() async throws {
        let slow = "https://files.example/slow.wad"
        StubURLProtocol.set(.stall(headers: ["Content-Length": "100000",
                                            "Content-Type": "application/octet-stream"],
                                   firstChunk: makeWAD(magic: "PWAD", lumps: ["MAP01"])), for: slow)
        let next = "https://files.example/next"
        serveWAD(at: next, named: "next.wad", lumps: ["MAP02"])
        let stack = try makeStack()
        let links = linkImport(for: stack)

        links.enqueue([URL(string: slow)!])
        let deadline = Date().addingTimeInterval(10)
        while StubURLProtocol.requestedURLs.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        links.cancel()
        XCTAssertFalse(links.isBusy, "a cancel ends the queue at once")
        links.enqueue([URL(string: next)!])
        while links.isBusy, Date() < deadline.addingTimeInterval(10) {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(try stack.library.allWADs().filter { !$0.isBundled }.map(\.filename), ["next.wad"])
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
