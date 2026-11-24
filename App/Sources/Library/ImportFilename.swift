import Foundation

/// The one place an incoming file's name is made safe to store and show
/// (#500 review). Every route's name passes through it on the way into the
/// library (`ImportService.importOneAsync`, which zip members also go
/// through), and `LinkDownloader` uses it for the file it saves, because a
/// download's name is whatever a server said.
enum ImportFilename {
    /// Longest name kept, in UTF-8 bytes. APFS allows 255; this leaves room
    /// for the " (12)" `WADStore` adds on a name collision.
    static let maxBytes = 200

    /// `name` as one safe path component:
    /// - control and format characters (a newline, a bell, a right-to-left
    ///   override) are dropped, so a name cannot break a banner line or
    ///   display reversed;
    /// - path separators and `:` become `_`;
    /// - leading dots and surrounding whitespace go, so the file is never
    ///   hidden and never `.` or `..`;
    /// - a name longer than `maxBytes` is shortened, keeping its extension;
    /// - nothing left, or a reserved device name such as `CON`, becomes
    ///   `fallback`.
    static func sanitized(_ name: String, fallback: String = "download") -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .unassigned, .privateUse:
                continue
            default:
                scalars.append(["/", "\\", ":"].contains(scalar) ? "_" : scalar)
            }
        }
        var cleaned = String(scalars).trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        let base = (cleaned as NSString).deletingPathExtension
        if cleaned.isEmpty || base.isEmpty || reserved.contains(base.uppercased()) {
            let ext = (cleaned as NSString).pathExtension
            return ext.isEmpty || base.isEmpty ? fallback : "\(fallback).\(ext)"
        }
        return shortened(cleaned)
    }

    /// Windows device names: harmless on iOS, but a file exported from the
    /// Files app to a PC under one of them cannot be opened there.
    private static let reserved: Set<String> = {
        var names: Set<String> = ["CON", "PRN", "AUX", "NUL"]
        for n in 1...9 { names.insert("COM\(n)"); names.insert("LPT\(n)") }
        return names
    }()

    /// `name` cut to `maxBytes` on a character boundary, extension kept. An
    /// extension too long to be a real one is cut with the rest.
    private static func shortened(_ name: String) -> String {
        guard name.utf8.count > maxBytes else { return name }
        var ext = (name as NSString).pathExtension
        var base = (name as NSString).deletingPathExtension
        if ext.utf8.count > 16 { ext = ""; base = name }
        let room = maxBytes - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        var cut = ""
        for character in base {
            if cut.utf8.count + String(character).utf8.count > room { break }
            cut.append(character)
        }
        cut = cut.trimmingCharacters(in: .whitespaces)
        return ext.isEmpty ? cut : "\(cut).\(ext)"
    }
}
