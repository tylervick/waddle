import Foundation
import Observation

/// A saved place to get games from (#502, named "Sources" by the owner).
///
/// A source names either a file, which a tap downloads through the link
/// import (`LinkImport`, #500), or a page, which a tap would open in the
/// in-app web view (#501). Both kinds are modelled, chosen per source; the
/// page kind stays out of the interface until #501 lands, so today no screen
/// creates, lists or opens one.
struct Source: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A link to one `.wad`, `.deh`, `.bex` or `.zip`: a tap downloads it.
        case file
        /// A web page the player picks a file on (needs #501's web view).
        case page
    }

    var id: UUID
    var name: String
    var url: URL
    var kind: Kind
    /// Lowercase hex SHA-256 the downloaded bytes must have, or nil for a
    /// player's own source, whose bytes nobody knows in advance. Only a
    /// source the app ships carries one.
    var sha256: String?
    /// The download's size in bytes, shown before the tap, or nil when it is
    /// not known in advance. Only a pinned source knows it: its bytes are
    /// fixed, so the size is too.
    var byteCount: Int64?

    init(id: UUID = UUID(), name: String, url: URL, kind: Kind, sha256: String? = nil,
         byteCount: Int64? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    /// Whether the app ships this source, rather than the player adding it.
    var isShipped: Bool { Source.shipped.contains { $0.id == id } }

    /// The Freedoom example, present on a fresh install (#502): the
    /// project's own GitHub release, both games in one zip.
    ///
    /// Pinned: the zip's SHA-256 is the value in that release's own
    /// `freedoom-0.13.0-CHECKSUM` file (PGP-signed by the Freedoom
    /// maintainers), and a download hashing to anything else is refused. A
    /// Freedoom release bump therefore needs an app update, which changes
    /// the link and the pin here together. Independent of
    /// `Scripts/fetch-freedoom.sh`'s `FREEDOOM_VERSION` (what the bundle
    /// carries) and of `LibraryService.shippedFreedoomSHA1` (what old
    /// builds carried); `IWADCatalog` names the WADs this zip holds.
    static let freedoom = Source(
        id: UUID(uuidString: "F4EED0F0-0502-4A5E-9C7B-000000013000")!,
        name: "Freedoom",
        url: URL(string: "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip")!,
        kind: .file,
        sha256: "3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59",
        byteCount: 24_143_781)

    /// Every source the app ships, in the order the list shows them.
    static let shipped: [Source] = [freedoom]
}

/// The player's sources (#502), persisted in `UserDefaults` as JSON.
///
/// Shipped sources live in code (`Source.shipped`), not in the stored list,
/// so an app update that moves a pin moves it for every install. What is
/// stored is the player's own sources and which shipped ones they deleted.
/// A deleted shipped source comes back with `restore(_:)`, the way Remove
/// from Shelf works for base games (#123); a player's own source, once
/// deleted, is gone.
///
/// Tolerant on read, like `TouchOverlayLayoutOverrides`: stored data that
/// does not decode reads as "nothing added, nothing deleted" rather than
/// taking the list down.
@MainActor
@Observable
final class SourceStore {
    static let userDefaultsKey = "sources"

    private struct Stored: Codable {
        var added: [Source] = []
        var deletedShipped: [UUID] = []
    }

    private let defaults: UserDefaults
    private var stored: Stored

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    /// Every source, shipped ones first, then the player's in the order
    /// they were added.
    var sources: [Source] {
        Source.shipped.filter { !stored.deletedShipped.contains($0.id) } + stored.added
    }

    /// Shipped sources the player deleted, for Restore.
    var deletedShipped: [Source] {
        Source.shipped.filter { stored.deletedShipped.contains($0.id) }
    }

    /// Adds a source the player named. The link must be one `LinkDownloader`
    /// takes (an `https` link with a host); otherwise nothing is added and
    /// the error says why. A blank name falls back to the link's host.
    @discardableResult
    func add(name: String, link: String, kind: Source.Kind = .file) -> Result<Source, LinkDownloadError> {
        switch LinkDownloader.validate(link) {
        case .failure(let error):
            return .failure(error)
        case .success(let url):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = Source(name: trimmed.isEmpty ? (url.host() ?? url.absoluteString) : trimmed,
                                url: url, kind: kind)
            stored.added.append(source)
            save()
            return .success(source)
        }
    }

    func delete(_ source: Source) {
        if source.isShipped {
            if !stored.deletedShipped.contains(source.id) { stored.deletedShipped.append(source.id) }
        } else {
            stored.added.removeAll { $0.id == source.id }
        }
        save()
    }

    func restore(_ source: Source) {
        stored.deletedShipped.removeAll { $0 == source.id }
        save()
    }

    private func save() {
        if stored.added.isEmpty && stored.deletedShipped.isEmpty {
            defaults.removeObject(forKey: Self.userDefaultsKey)
        } else if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
