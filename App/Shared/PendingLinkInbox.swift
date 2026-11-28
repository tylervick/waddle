import Foundation

/// The hand-off from the share extension to the app (#551).
///
/// An app extension cannot open its containing app, and the two cannot reach
/// each other's containers, so a link shared from Safari waits here, in the
/// App Group's container, until Waddle next opens: the extension `add`s it,
/// and the app `take`s it and queues it on `LinkImport`, as a dropped link
/// is (`SharedLinks.pickUp`).
///
/// One small JSON file per link, holding the link and when it was shared.
/// A file and not `UserDefaults(suiteName:)` on purpose: `UserDefaults` is a
/// required-reason API, and this way the extension uses none. The time is
/// written into the file, never read from its attributes, for the same
/// reason: file timestamps are a required-reason API too.
///
/// Compiled into both targets, Foundation only.
struct PendingLinkInbox: Sendable {
    /// A link waiting longer than this is dropped without a word: a player
    /// who shared it a week ago and never opened Waddle has moved on.
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// The most links that wait at once. The share sheet refuses another
    /// until Waddle has opened and taken them, as a drop takes no more than
    /// `WADDrop.maxLinksPerDrop`.
    static let capacity = 10
    /// The folder in the App Group's container.
    static let folderName = "Pending Links"
    /// The Info.plist key both targets carry the App Group's identifier
    /// under, from the `WADDLE_APP_GROUP` build setting that their
    /// entitlements use too (`App/project.yml`).
    static let appGroupInfoKey = "WaddleAppGroup"

    /// Why a link was not added.
    enum Refusal: Error, Equatable {
        /// Not a link Waddle downloads: the app's own reason.
        case link(LinkDownloadError)
        /// `capacity` links are already waiting.
        case full
        /// The container could not be written.
        case unwritable

        var reason: String {
            switch self {
            case .link(let error): return error.reason
            case .full:
                return "Waddle already has \(PendingLinkInbox.capacity) links waiting. Open Waddle to download them, then share this one again."
            case .unwritable:
                return "Waddle could not save this link. Copy it, and add it in Waddle with Add → From a Link…"
            }
        }
    }

    /// One waiting link, as written to its file.
    struct Entry: Codable, Equatable {
        var url: URL
        var sharedAt: Date
    }

    let directory: URL
    var now: @Sendable () -> Date = { Date() }

    init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// The inbox in this process's App Group container, or nil when the
    /// process has no App Group: a build signed without its entitlements,
    /// such as CI's unsigned simulator builds.
    static func shared(bundle: Bundle = .main) -> PendingLinkInbox? {
        guard let group = bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String, !group.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        return PendingLinkInbox(directory: container.appendingPathComponent(folderName, isDirectory: true))
    }

    /// Adds `text`'s link to wait for the app, unless the app would refuse
    /// it, `capacity` links already wait, or it cannot be written. Returns
    /// the link as it will be downloaded.
    @discardableResult
    func add(_ text: String) -> Result<URL, Refusal> {
        let url: URL
        switch WebLink.validate(text) {
        case .failure(let error): return .failure(.link(error))
        case .success(let valid): url = valid
        }
        if waitingFiles().count >= Self.capacity { return .failure(.full) }
        let date = now()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Entry(url: url, sharedAt: date))
            // Written whole, under its final name, in one rename: the app
            // never sees half a file.
            let millis = Int64((date.timeIntervalSince1970 * 1000).rounded())
            let name = "\(millis)-\(UUID().uuidString).json"
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return .failure(.unwritable)
        }
        return .success(url)
    }

    /// The waiting links, oldest first, at most `limit` of them, each now
    /// removed from the inbox so it is taken once. Any over `limit` stay for
    /// the next call. A file that does not decode, and a link older than
    /// `maxAge`, are removed and not returned.
    ///
    /// The links are returned as they were written; the caller checks them
    /// again before downloading, as it checks a dropped link.
    func take(limit: Int = .max) -> [URL] {
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        var waiting: [(entry: Entry, file: URL)] = []
        for file in waitingFiles() {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.sharedAt >= cutoff else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            waiting.append((entry, file))
        }
        // By the time written into each file, then by name, so two shared
        // in the same instant still come out in one order.
        waiting.sort {
            ($0.entry.sharedAt, $0.file.lastPathComponent) < ($1.entry.sharedAt, $1.file.lastPathComponent)
        }
        let taken = waiting.prefix(max(0, limit))
        for item in taken { try? FileManager.default.removeItem(at: item.file) }
        return taken.map(\.entry.url)
    }

    /// The inbox's link files. No attributes are asked for: see the type's
    /// comment.
    private func waitingFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [], options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }
    }
}
