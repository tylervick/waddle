import Foundation
import Observation

/// The one Freedoom release the Get Freedoom tile downloads (#552): the
/// file the owner chose on 2026-11-23 (#502), pinned by its SHA-256 and
/// shown by its size before anything is fetched.
enum FreedoomRelease {
    /// Freedoom 0.13.0's release zip on GitHub, which holds `freedoom1.wad`
    /// and `freedoom2.wad` beside their documents.
    static let url = URL(string: "https://github.com/freedoom/freedoom/releases/download/v0.13.0/freedoom-0.13.0.zip")!
    /// From the release's PGP-signed `freedoom-0.13.0-CHECKSUM`. Bytes that
    /// hash to anything else are refused (`LinkDownloadError.checksumMismatch`).
    static let sha256 = "3f9b264f3e3ce503b4fb7f6bdcb1f419d93c7b546f4df3e874dd878db9688f59"
    /// The zip's size, known in advance so the tile can say it before the
    /// tap (App Review Guideline 4.2.3(ii)) without asking the network.
    static let byteCount: Int64 = 24_143_781
    /// SHA-1 of the two WADs inside: the same Freedoom 0.13.0 the app has
    /// bundled, so the same as `LibraryService.shippedFreedoomSHA1`
    /// (`GetFreedoomTests` holds them together) and `IWADCatalog`'s titles.
    static let wadSHA1s: Set<String> = [
        "97bb88094a51457a8dcad98c58be22a2d0fa9a37",   // freedoom1.wad
        "975f781e6d801c0a23e3caa33f70493efe68a880",   // freedoom2.wad
    ]

    /// `byteCount` as the tile shows it: "24.1 MB".
    static var sizeText: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

/// The Get Freedoom tile's state and its one action (#552). It drives the
/// shelf's shared `LinkImport`, so it and **From a Link…** never download
/// at the same time: whichever starts first holds it, and the other waits.
@MainActor
@Observable
final class GetFreedoom {
    /// What the tile shows.
    enum State: Equatable {
        /// **Get**, with the size, and the short reason the last try
        /// failed when it did.
        case offered(failure: String?)
        /// Bytes so far, and the total when known.
        case downloading(received: Int64, expected: Int64?)
        /// The zip arrived and is being added.
        case importing
    }

    let link: LinkImport
    /// The short reason the last tap failed. In memory only: a relaunch
    /// clears it, and so does a download that arrives.
    private(set) var failure: String?
    #if DEBUG
    /// Test-only: a state the tile shows whatever the download is doing, so
    /// a capture can show each one with no network (`WADDLE_TEST_GET_FREEDOOM`).
    var forcedState: State?
    #endif

    /// The link and its pin. Production always downloads `FreedoomRelease`;
    /// a test passes a pin its own stand-in zip matches, since the release's
    /// own bytes are not in the repository.
    private let url: URL
    private let sha256: String

    init(link: LinkImport, url: URL = FreedoomRelease.url, sha256: String = FreedoomRelease.sha256) {
        self.link = link
        self.url = url
        self.sha256 = sha256
    }

    /// Whether the running download is this tile's, not a pasted link's.
    private var ownsDownload: Bool { link.currentURL == url }

    var state: State {
        #if DEBUG
        if let forcedState { return forcedState }
        #endif
        guard ownsDownload else { return .offered(failure: failure) }
        switch link.phase {
        case .idle: return .offered(failure: failure)
        case .downloading(let received, let expected): return .downloading(received: received, expected: expected)
        case .importing: return .importing
        }
    }

    /// True while **From a Link…** is downloading: **Get** waits for it.
    var isBlocked: Bool { link.isBusy && !ownsDownload }

    /// Starts the download. `onFinish` runs once it has ended, however it
    /// ended. The full reason for a failure goes to the import banner, as
    /// every link failure's does; the tile keeps a short one.
    @discardableResult
    func get(onFinish: @escaping @MainActor () -> Void = {}) -> Bool {
        link.start(url, expectedSHA256: sha256) { [weak self] outcome in
            guard let self else { return }
            if let error = self.link.lastFailure {
                self.failure = Self.shortReason(error)
            } else if let outcome, outcome.games.isEmpty, outcome.imported.isEmpty, outcome.duplicates.isEmpty {
                // Downloaded and checked, yet nothing was added: the banner
                // has the import's own reason.
                self.failure = "Couldn't add it"
            } else if outcome != nil {
                self.failure = nil
            }
            // A cancel (no outcome, no failure) goes back to Get silently,
            // keeping any earlier reason until a download arrives.
            onFinish()
        }
    }

    func cancel() {
        guard ownsDownload else { return }
        link.cancel()
    }

    /// A failure's reason in a few words, to fit under the tile's size.
    nonisolated static func shortReason(_ error: LinkDownloadError) -> String {
        switch error {
        case .offline: return "You're offline"
        case .checksumMismatch: return "Not the expected file"
        default: return "Download failed"
        }
    }
}
