#if DEBUG
import Foundation

// THROWAWAY PROTOTYPE (branch tylervick/proto-browser-mockups, never merged).
// Mockups of an in-app browser for issue #501. Every screen here is hard-coded
// state chosen by WADDLE_PROTO="<direction>/<scene>" at launch, so a host
// script can photograph it. Nothing here is wired to the real import path.

enum ProtoDirection: String {
    /// A: "From the Web…" in the Add menu opens a full-screen browser with
    /// Safari-like chrome and a start page that features Freedoom.
    case a
    /// B: a globe button beside Add opens a chrome-light browser beside the
    /// shelf (the panel column) or pushed on a phone; no start page.
    case b
    /// C: the browser is a second tab, a whole browser: address bar, tabs,
    /// bookmarks, a downloads list, and a New Tab page.
    case c
}

enum ProtoShelfState {
    case empty
    case freedoom
    case freedoomAndScythe
}

struct ProtoFile {
    let name: String
    let bytes: Int64
    let host: String

    var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

    static let freedoom = ProtoFile(name: "freedoom-0.13.0.zip", bytes: 24_143_781, host: "github.com")
    static let scythe = ProtoFile(name: "scythe.zip", bytes: 2_086_863, host: "youfailit.net")
    static let apk = ProtoFile(name: "doom-release.apk", bytes: 38_611_392, host: "github.com")
}

struct ProtoPage {
    let url: URL
    /// A CSS selector scrolled to the middle of the page once it loads.
    var focus: String?
    /// Draw the focused link as if a finger is on it.
    var pressed = false
    /// How many CSS px wide the zoomed view of a desktop page is.
    var zoomWidth: Double = 560

    static let freedoomURL = URL(string: "https://freedoom.github.io/download.html")!
    static let idgamesURL = URL(string: "https://youfailit.net/pub/idgames/levels/doom2/megawads/")!
    static let apkURL = URL(string: "https://github.com/mkrupczak3/Freedoom-for-Android/releases/tag/v0.4.3")!
    static let loginURL = URL(string: "https://github.com/login")!

    static let freedoomLink = "a[href$=\"freedoom-0.13.0.zip\"]"
    static let scytheLink = "a[href=\"scythe.zip\"]"
    static let apkLink = "a[href$=\"doom-release.apk\"]"

    static func freedoom(pressed: Bool = false) -> ProtoPage {
        ProtoPage(url: freedoomURL, focus: freedoomLink, pressed: pressed, zoomWidth: 600)
    }
    static func idgames(pressed: Bool = false) -> ProtoPage {
        ProtoPage(url: idgamesURL, focus: scytheLink, pressed: pressed)
    }
    static func apk(pressed: Bool = false) -> ProtoPage {
        ProtoPage(url: apkURL, focus: apkLink, pressed: pressed)
    }
    static let login = ProtoPage(url: loginURL)

    var host: String { url.host() ?? "" }
}

enum ProtoBrowserContent {
    case start
    case page(ProtoPage)
}

enum ProtoOverlay {
    case none
    case confirm(ProtoFile)
    case progress(ProtoFile, received: Int64)
    case done(ProtoFile, games: String)
    case notGame(ProtoFile)
    case signIn
    case downloads
    case address
}

struct ProtoScene {
    let direction: ProtoDirection
    var shelf: ProtoShelfState = .freedoom
    /// nil: the browser is closed (C: the Shelf tab is selected).
    var browser: ProtoBrowserContent?
    var overlay: ProtoOverlay = .none
    /// The import banner over the shelf.
    var banner: String?
    /// Tiles drawn with the accent ring, as just arrived.
    var fresh: Set<String> = []

    static var current: ProtoScene? {
        guard let raw = ProcessInfo.processInfo.environment["WADDLE_PROTO"] else { return nil }
        let parts = raw.split(separator: "/").map(String.init)
        guard parts.count == 2, let direction = ProtoDirection(rawValue: parts[0]) else { return nil }
        return scene(direction, parts[1])
    }

    static let freedoomBanner = "Added Freedoom Phase 1, Freedoom Phase 2"
    static let scytheBanner = "Added scythe"
    static let freedoomFresh: Set<String> = ["Freedoom Phase 1", "Freedoom Phase 2"]

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func scene(_ d: ProtoDirection, _ name: String) -> ProtoScene {
        var s = ProtoScene(direction: d)
        let start: ProtoBrowserContent = d == .b ? .page(.freedoom()) : .start
        switch name {
        case "empty-shelf":
            s.shelf = .empty
        case "entry":
            // The shelf of a player who has games, with the way in visible.
            s.shelf = .freedoom
        case "start":
            s.shelf = .empty
            s.browser = start
            if d == .b {
                // B has no start page: the featured tile opens Freedoom's
                // page with its download already offered.
                s.browser = .page(.freedoom(pressed: true))
                s.overlay = .confirm(.freedoom)
            }
        case "freedoom-page":
            s.shelf = .empty
            s.browser = .page(.freedoom())
        case "freedoom-confirm":
            s.shelf = .empty
            s.browser = .page(.freedoom(pressed: true))
            s.overlay = .confirm(.freedoom)
        case "freedoom-progress":
            s.shelf = .empty
            s.browser = .page(.freedoom())
            s.overlay = .progress(.freedoom, received: 10_590_000)
        case "freedoom-done":
            // B only: the panel still open, the shelf beside it filled.
            s.shelf = .freedoom
            s.browser = .page(.freedoom())
            s.overlay = .done(.freedoom, games: "Freedoom Phase 1 and Phase 2")
            s.fresh = freedoomFresh
        case "freedoom-arrived":
            s.shelf = .freedoom
            s.banner = freedoomBanner
            s.fresh = freedoomFresh
        case "idgames-page":
            s.browser = .page(.idgames())
        case "idgames-confirm":
            s.browser = .page(.idgames(pressed: true))
            s.overlay = .confirm(.scythe)
        case "idgames-progress":
            s.browser = .page(.idgames())
            s.overlay = .progress(.scythe, received: 1_310_000)
        case "idgames-arrived":
            s.shelf = .freedoomAndScythe
            s.banner = scytheBanner
            s.fresh = ["Scythe"]
        case "not-a-game":
            s.browser = .page(.apk(pressed: true))
            s.overlay = .notGame(.apk)
        case "sign-in":
            s.browser = .page(.login)
            s.overlay = .signIn
        case "downloads":
            s.shelf = .freedoom
            s.browser = .page(.idgames())
            s.overlay = .downloads
        case "address":
            s.browser = .page(.idgames())
            s.overlay = .address
        case "menu":
            // The browser's own menu, opened by a UI-test tap.
            s.browser = .page(.idgames())
        default:
            break
        }
        return s
    }
}
#endif
