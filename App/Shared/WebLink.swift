import Foundation

// Compiled into both the app and the share extension (#551), so a link the
// extension takes is one the app downloads, and one it refuses is refused
// with the app's own words. Foundation only: an extension may not use
// `UIApplication.shared`, and this target sets APPLICATION_EXTENSION_API_ONLY.

/// Why a link the player gave could not be downloaded (#500). Every case but
/// cancellation ends in the import notice, so each `reason` says what the
/// player can do about it.
enum LinkDownloadError: Error, Equatable, Sendable {
    /// Not something a download can start from: empty, or no host.
    case notALink
    /// A plain `http` link, or an `https` one that redirects to `http`. The
    /// app has no App Transport Security exception and gets none.
    case insecure
    case offline
    /// The device is online but the server cannot be found or reached.
    case unreachable
    /// The server answered with something other than a 2xx status.
    case httpStatus(Int)
    /// The file is over `LinkDownloader.maxBytes`, by its `Content-Length`
    /// or by what actually arrived.
    case tooLarge(limit: Int64)
    /// The body is a web page: a mirror's landing page, not its file.
    case webPage
    /// The file is named as a type Waddle refuses (a `.pk3`), by the
    /// server's filename or the link's.
    case refusedType(String)
    /// The body is neither a web page nor anything Waddle takes: an API's
    /// JSON error, say, or a text file.
    case notAGameFile
    /// Any other transport failure, with the system's own description.
    case failed(String)
    /// A shared link (#551) whose download Waddle started and never
    /// finished: the app stopped (killed, or crashed) while adding it. It
    /// is dropped rather than tried again, so a file that crashes the
    /// import cannot crash every launch.
    case interrupted

    var reason: String {
        switch self {
        case .notALink:
            return "That is not a web link. Paste a link that starts with https://."
        case .insecure:
            return "Waddle only downloads secure links. Use the https:// version of the link."
        case .offline:
            return "You appear to be offline. Connect to the internet and try again."
        case .unreachable:
            return "Waddle could not reach the server. Check the link and try again."
        case .httpStatus(404):
            return "The server has no file at that link (error 404). Check the link and try again."
        case .httpStatus(let code):
            return "The server refused the download (error \(code)). Check the link, or try again later."
        case .tooLarge(let limit):
            return "The file is larger than the \(limit / (1024 * 1024)) MB import limit."
        case .webPage:
            return "That link opens a web page, not a file. Find the download link on the page and use that instead."
        case .refusedType(let ext):
            return "That link leads to a .\(ext) file, which Waddle does not take. Waddle takes .wad, .deh, .bex and .zip files."
        case .notAGameFile:
            return "That link did not lead to a game file. Waddle takes .wad, .deh, .bex and .zip files; check that the link is to the file itself."
        case .failed(let description):
            return "The download failed: \(description)"
        case .interrupted:
            return "Waddle stopped while adding it. Share it to Waddle again to try once more."
        }
    }
}

/// The one check a link passes before Waddle downloads it, wherever it came
/// from: the From a Link field, a drop, or the share sheet.
enum WebLink {
    /// The `https` URL `text` names, or why it names none. Surrounding
    /// whitespace is ignored, since a pasted link often carries some.
    static func validate(_ text: String) -> Result<URL, LinkDownloadError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host(), !host.isEmpty else {
            return .failure(.notALink)
        }
        switch scheme {
        case "https": return .success(url)
        case "http": return .failure(.insecure)
        default: return .failure(.notALink)
        }
    }
}
