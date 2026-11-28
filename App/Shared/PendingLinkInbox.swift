import Foundation

/// The hand-off from the share extension to the app (#551).
///
/// An app extension cannot open its containing app, and the two cannot reach
/// each other's containers, so a link shared from Safari waits here, in the
/// App Group's container, until Waddle next opens: the extension `add`s it,
/// and the app reads it (`waiting`), queues it on `LinkImport` as a dropped
/// link is, and `remove`s it once its download has ended in a result the
/// player was shown (`SharedLinkPickup`).
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
    /// The most links that wait at once, one per slot file. The share sheet
    /// refuses another until Waddle has opened and downloaded them, as a
    /// drop takes no more than `WADDrop.maxLinksPerDrop`.
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
        /// When the app started downloading it (`markAttempted`); nil until
        /// then. A link found with this set and not in the app's current
        /// queue was being added when the app stopped.
        var attemptedAt: Date?
    }

    /// How long a staged file may sit before the app sweeps it: far longer
    /// than any write, so only a writer that was killed leaves one this old.
    static let staleStagingAge: TimeInterval = 5 * 60
    /// The prefix of a link's staged file, written whole before it is
    /// renamed onto a slot. Hidden, so `waiting` never reads one.
    static let stagingPrefix = ".writing-"

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
    ///
    /// The cap holds with several writers at once (two Safari windows on an
    /// iPad each running the extension): a link is written whole under a
    /// hidden name, then renamed onto one of `capacity` slot names with
    /// `RENAME_EXCL`, which the file system refuses if that name exists. A
    /// writer that finds every slot taken gets `.full`. Counting the files
    /// and then writing was not atomic: 40 writers at once left 19 (review
    /// of pull request 561).
    @discardableResult
    func add(_ text: String) -> Result<URL, Refusal> {
        let url: URL
        switch WebLink.validate(text) {
        case .failure(let error): return .failure(.link(error))
        case .success(let valid): url = valid
        }
        // The time is in the name, not read from the file's attributes
        // (a required-reason API), so the app can sweep one a killed
        // extension left behind (`sweepStaleStaging`).
        let millis = Int64((now().timeIntervalSince1970 * 1000).rounded())
        let staged = directory.appendingPathComponent("\(Self.stagingPrefix)\(millis)-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Entry(url: url, sharedAt: now()))
            try data.write(to: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            return .failure(.unwritable)
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        for slot in 0..<Self.capacity {
            let target = directory.appendingPathComponent(Self.slotName(slot))
            if renamex_np(staged.path, target.path, UInt32(RENAME_EXCL)) == 0 { return .success(url) }
            guard errno == EEXIST else { return .failure(.unwritable) }
        }
        return .failure(.full)
    }

    /// The file name of slot `index`.
    static func slotName(_ index: Int) -> String { "link-\(index).json" }

    /// One link waiting in the inbox, and the file that holds it.
    struct Pending: Equatable, Sendable {
        var url: URL
        var sharedAt: Date
        var file: URL
        /// Whether a download of it was started (`markAttempted`).
        var attempted = false
    }

    /// The links waiting, oldest first, at most `limit` of them. They stay
    /// in the inbox until `remove` is called for them: the app removes a
    /// link once its download has ended in a result the player was shown,
    /// so one lost to the app being killed mid-download is picked up again.
    /// A file that does not decode, and a link older than `maxAge`, are
    /// deleted here and not returned.
    ///
    /// The links are returned as they were written; the caller checks them
    /// again before downloading, as it checks a dropped link.
    func waiting(limit: Int = .max) -> [Pending] {
        sweepStaleStaging()
        let cutoff = now().addingTimeInterval(-Self.maxAge)
        var waiting: [Pending] = []
        for file in waitingFiles() {
            guard let data = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.sharedAt >= cutoff else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            waiting.append(Pending(url: entry.url, sharedAt: entry.sharedAt, file: file,
                                   attempted: entry.attemptedAt != nil))
        }
        // By the time written into each file, then by name, so two shared
        // in the same instant still come out in one order.
        waiting.sort { ($0.sharedAt, $0.file.lastPathComponent) < ($1.sharedAt, $1.file.lastPathComponent) }
        return Array(waiting.prefix(max(0, limit)))
    }

    /// Records in each of `items`' files that its download is starting, so a
    /// later pick-up can tell a link the app stopped while adding. Written
    /// in place, atomically; a file that cannot be rewritten is removed
    /// instead, so a link is never downloaded unmarked.
    func markAttempted(_ items: [Pending]) {
        let date = now()
        for item in items {
            let entry = Entry(url: item.url, sharedAt: item.sharedAt, attemptedAt: date)
            do {
                try JSONEncoder().encode(entry).write(to: item.file, options: .atomic)
            } catch {
                try? FileManager.default.removeItem(at: item.file)
            }
        }
    }

    /// Deletes staged files older than `staleStagingAge`: what an extension
    /// killed between writing and renaming leaves behind (review of pull
    /// request 561). Their age is read from their names.
    func sweepStaleStaging() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let cutoff = (now().timeIntervalSince1970 - Self.staleStagingAge) * 1000
        for name in names where name.hasPrefix(Self.stagingPrefix) {
            let stamp = name.dropFirst(Self.stagingPrefix.count).prefix { $0 != "-" }
            // A name with no readable time is not one `add` wrote: also swept.
            if let millis = Double(stamp), millis >= cutoff { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Removes `items` from the inbox, freeing their slots.
    func remove(_ items: [Pending]) {
        for item in items { try? FileManager.default.removeItem(at: item.file) }
    }

    /// The inbox's link files. No attributes are asked for: see the type's
    /// comment.
    private func waitingFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [], options: [.skipsHiddenFiles])) ?? []
        return files.filter { $0.pathExtension == "json" }
    }
}
