import XCTest
@testable import Waddle

/// Issue #484: "Report a bug" and "Send feedback" on the About screen.
final class FeedbackRoutesTests: XCTestCase {
    /// Spaces, parentheses and a query metacharacter, so encoding is exercised.
    private let facts = DeviceFacts(appVersion: "1.5 (295)",
                                    iosVersion: "Version 27.1 (Build 24B83) & more",
                                    device: "iPhone16,1")

    // MARK: Report a bug

    func testBugReportURLCarriesExactlyTheTemplateAndTheThreeFacts() throws {
        let url = BugReport.url(facts: facts)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/tylervick/waddle/issues/new")

        let items = try XCTUnwrap(components.queryItems)
        XCTAssertEqual(items.map(\.name), ["template", "app_version", "ios_version", "device"],
                       "the URL carries these four items and nothing else")
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
        XCTAssertEqual(values["template"], "bug_report.yml")
        // Decoded values round-trip exactly, spaces and parentheses included.
        XCTAssertEqual(values["app_version"], "1.5 (295)")
        XCTAssertEqual(values["ios_version"], "Version 27.1 (Build 24B83) & more")
        XCTAssertEqual(values["device"], "iPhone16,1")
    }

    func testBugReportURLIsPercentEncoded() {
        let query = BugReport.url(facts: facts).query ?? ""
        XCTAssertFalse(query.contains(" "), "spaces are encoded: \(query)")
        // Parentheses are legal in a query and may stay; the round trip
        // above is what proves they survive.
        XCTAssertTrue(query.contains("app_version=1.5%20(295)"), query)
        XCTAssertTrue(query.contains("%26%20more"), "an & inside a value is encoded: \(query)")
    }

    func testBugReportURLCarriesNoLibraryLine() {
        // A GitHub issue is public; a WAD's file name can be private.
        // The query only: the repository path itself contains "wad".
        let query = (BugReport.url(facts: facts).query ?? "").removingPercentEncoding ?? ""
        for marker in ["wad", "game", "library", "freedoom"] {
            XCTAssertFalse(query.lowercased().contains(marker),
                           "\(marker) must not reach the public form: \(query)")
        }
    }

    func testBugReportConfirmationShowsTheLiteralValues() {
        let message = BugReport.confirmationMessage(facts: facts)
        XCTAssertTrue(message.contains("1.5 (295)"))
        XCTAssertTrue(message.contains("Version 27.1 (Build 24B83) & more"))
        XCTAssertTrue(message.contains("iPhone16,1"))
        XCTAssertTrue(message.contains("public"))
    }

    // MARK: Send feedback

    func testMailCompositionAddressesTheOwnerWithInfoBlockAndOneAttachment() throws {
        let zip = URL(fileURLWithPath: "/tmp/diagnostics-export-x/Waddle-diagnostics.zip")
        let outcome = try FeedbackMail.prepare(canSendMail: true, facts: facts) { zip }
        guard case .compose(let mail) = outcome else {
            return XCTFail("expected a mail sheet, got \(outcome)")
        }
        XCTAssertEqual(mail.recipients, ["apple@milo.cat"])
        XCTAssertEqual(mail.subject, "Waddle feedback – 1.5 (295)")
        XCTAssertTrue(mail.body.hasPrefix("\n"), "starts with an empty line for the user's text")
        XCTAssertTrue(mail.body.contains("app version: 1.5 (295)"))
        XCTAssertTrue(mail.body.contains("iOS: Version 27.1 (Build 24B83) & more"))
        XCTAssertTrue(mail.body.contains("device: iPhone16,1"))
        XCTAssertEqual(mail.attachments.count, 1)
        XCTAssertEqual(mail.attachments.first?.fileName, "Waddle-diagnostics.zip")
        XCTAssertEqual(mail.attachments.first?.mimeType, "application/zip")
        XCTAssertEqual(mail.attachments.first?.url, zip)
    }

    func testMailAttachmentIsTheRealDiagnosticsExport() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("feedback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let outcome = try FeedbackMail.prepare(canSendMail: true, facts: facts) {
            try DiagnosticsExporter.export(diagnosticsDirectory: tmp, libraryLines: [])
        }
        guard case .compose(let mail) = outcome else {
            return XCTFail("expected a mail sheet, got \(outcome)")
        }
        let attachment = try XCTUnwrap(mail.attachments.first)
        XCTAssertEqual(attachment.fileName, "Waddle-diagnostics.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.url.path))
        try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
    }

    func testNoMailAccountGivesTheAlertAndBuildsNoFile() throws {
        var exported = false
        let outcome = try FeedbackMail.prepare(canSendMail: false, facts: facts) {
            exported = true
            return URL(fileURLWithPath: "/tmp/never.zip")
        }
        XCTAssertEqual(outcome, .unavailable(address: "apple@milo.cat"),
                       "no mail account means the alert, never a mail sheet")
        XCTAssertFalse(exported, "nothing is assembled when there is no sheet to attach it to")
    }

    // MARK: One source for the three facts

    func testDiagnosticsInfoTextUsesTheSharedFacts() {
        let current = DeviceFacts.current
        let text = DiagnosticsExporter.infoText(libraryLines: [])
        XCTAssertTrue(text.contains("app version: \(current.appVersion)"))
        XCTAssertTrue(text.contains("iOS: \(current.iosVersion)"))
        XCTAssertTrue(text.contains("device: \(current.device)"))
    }
}
