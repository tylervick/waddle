import Foundation

/// The three facts every feedback route shares: the app's version and build,
/// the OS version, and the device model. Read in one place so the diagnostics
/// file, the bug-report form and the feedback email cannot drift apart.
struct DeviceFacts: Equatable {
    /// `CFBundleShortVersionString (CFBundleVersion)`, e.g. `1.5 (295)`.
    var appVersion: String
    /// `ProcessInfo.operatingSystemVersionString`, e.g. `Version 27.1 (Build 24B83)`.
    var iosVersion: String
    /// The `utsname` machine string, e.g. `iPhone16,1`.
    var device: String

    static var current: DeviceFacts {
        var model = utsname()
        uname(&model)
        let device = withUnsafeBytes(of: &model.machine) { buf in
            String(decoding: buf.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let bundle = Bundle.main
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildNumber = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return DeviceFacts(appVersion: "\(version) (\(buildNumber))",
                           iosVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                           device: device)
    }

    /// One line for the user to read before anything leaves the app.
    var summary: String { "Waddle \(appVersion) · iOS \(iosVersion) · \(device)" }
}

/// "Report a bug": the repository's bug-report issue form, opened in the
/// browser with the three facts filled in (issue #484).
///
/// A GitHub issue is public and a WAD's file name can be private, so the URL
/// carries the three facts and nothing else: no library lines, no WAD or game
/// names. The query reaches github.com as soon as the page loads, which is
/// why the About screen shows `confirmationMessage` before opening it.
enum BugReport {
    static let newIssueURL = "https://github.com/tylervick/waddle/issues/new"
    /// `.github/ISSUE_TEMPLATE/bug_report.yml`; the item names below are its
    /// field ids, which is how GitHub prefills a form from the query.
    static let template = "bug_report.yml"

    static func url(facts: DeviceFacts) -> URL {
        // `urlQueryAllowed` lets `&`, `=`, `+` and `?` through unencoded; a
        // value containing one would split or corrupt the query.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        func item(_ name: String, _ value: String) -> URLQueryItem {
            URLQueryItem(name: name,
                         value: value.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        var components = URLComponents(string: newIssueURL)!
        components.percentEncodedQueryItems = [
            item("template", template),
            item("app_version", facts.appVersion),
            item("ios_version", facts.iosVersion),
            item("device", facts.device),
        ]
        return components.url!
    }

    static func confirmationMessage(facts: DeviceFacts) -> String {
        "Opens GitHub in your browser. You'll need a GitHub account, and your report will be public. "
            + "The form starts filled in with: \(facts.summary). "
            + "You can edit or delete these before submitting."
    }
}

/// "Send feedback": the system mail sheet, addressed to the owner, with the
/// same diagnostics file "Export Diagnostics" produces attached (issue #484).
/// The user sees the recipient, their own From address and the attachment,
/// and sends it themselves; the app keeps no copy and records nothing.
enum FeedbackMail {
    /// The owner's address (owner decision on issue #484, 2026-11-22). It
    /// ships in the binary and is shown to every user who taps the row.
    static let recipient = "apple@milo.cat"
    static let attachmentMimeType = "application/zip"

    struct Attachment: Equatable {
        var fileName: String
        var mimeType: String
        var url: URL
    }

    struct Composition: Equatable {
        var recipients: [String]
        var subject: String
        var body: String
        var attachments: [Attachment]
    }

    /// What tapping the row leads to.
    enum Outcome: Equatable {
        /// The mail sheet, filled in.
        case compose(Composition)
        /// No mail account: an alert that names the address and offers to
        /// copy it or export the diagnostics instead. Never a `mailto:` URL,
        /// which cannot carry the attachment.
        case unavailable(address: String)
    }

    static func subject(facts: DeviceFacts) -> String {
        "Waddle feedback – \(facts.appVersion)"
    }

    /// An empty first line for the user's own text, then the three facts.
    static func body(facts: DeviceFacts) -> String {
        [
            "",
            "",
            "---",
            "app version: \(facts.appVersion)",
            "iOS: \(facts.iosVersion)",
            "device: \(facts.device)",
        ].joined(separator: "\n")
    }

    static func composition(facts: DeviceFacts, diagnosticsZip: URL) -> Composition {
        Composition(recipients: [recipient],
                    subject: subject(facts: facts),
                    body: body(facts: facts),
                    attachments: [Attachment(fileName: diagnosticsZip.lastPathComponent,
                                             mimeType: attachmentMimeType,
                                             url: diagnosticsZip)])
    }

    /// Decides the outcome. `canSendMail` is injected so a test does not
    /// depend on the simulator's mail state; the diagnostics file is built
    /// only when there is a mail sheet to attach it to.
    static func prepare(canSendMail: Bool,
                        facts: DeviceFacts,
                        exportDiagnostics: () throws -> URL) throws -> Outcome {
        guard canSendMail else { return .unavailable(address: recipient) }
        return .compose(composition(facts: facts, diagnosticsZip: try exportDiagnostics()))
    }
}
