import XCTest
@testable import Waddle

/// The catalog's colours, held to the contrast the visual system claims for
/// them (spec §5, amended 2026-08-17; design-system spec §6).
///
/// Read from the colorsets' JSON rather than from `UIColor`, on purpose: the
/// claim is about the values the catalog *ships*, and a resolved `UIColor`
/// would pass through whatever appearance the test host happens to be in.
/// Reading the JSON also catches the one regression the spec warns about —
/// a second appearance entry quietly reintroducing a light variant — because
/// such a colorset no longer has exactly one colour.
///
/// Why this is a test and not a note: the accent is light, so anything that
/// fills with it needs a dark label. That sentence lived in `Theme` for six
/// weeks while the game page shipped `.borderedProminent`'s white-on-green
/// at 1.29:1. A ratio nobody computes is a ratio nobody keeps.
final class ThemeContrastTests: XCTestCase {

    private struct Catalog {
        let background: RGB
        let surface: RGB
        let secondaryText: RGB
        let accent: RGB
        let warning: RGB
        let danger: RGB
    }

    private struct RGB {
        let r: Double, g: Double, b: Double

        /// WCAG 2 relative luminance.
        var luminance: Double {
            func channel(_ c: Double) -> Double {
                c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
        }

        static let black = RGB(r: 0, g: 0, b: 0)
        static let white = RGB(r: 1, g: 1, b: 1)
    }

    private static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    /// The colorset directory, found from this file: the catalog is a source
    /// input, not a bundle resource, and the test bundle does not carry it.
    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // App/
            .appendingPathComponent("Assets.xcassets")
    }

    private static func color(named name: String) throws -> RGB {
        let url = catalogURL.appendingPathComponent("\(name).colorset/Contents.json")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let colors = try XCTUnwrap(json["colors"] as? [[String: Any]])
        XCTAssertEqual(colors.count, 1,
                       "\(name) must have exactly one universal colour: a second entry is a light variant (spec §5)")
        let entry = try XCTUnwrap(colors.first)
        XCTAssertNil((entry["appearances"] as? [[String: Any]]),
                     "\(name) must not carry an appearance qualifier (spec §5)")
        let color = try XCTUnwrap(entry["color"] as? [String: Any])
        let components = try XCTUnwrap(color["components"] as? [String: String])
        func component(_ key: String) throws -> Double {
            try XCTUnwrap(Double(try XCTUnwrap(components[key])), "\(name).\(key)")
        }
        return RGB(r: try component("red"), g: try component("green"), b: try component("blue"))
    }

    private func catalog() throws -> Catalog {
        Catalog(background: try Self.color(named: "AppBackground"),
                surface: try Self.color(named: "AppSurface"),
                secondaryText: try Self.color(named: "AppSecondaryText"),
                accent: try Self.color(named: "AccentColor"),
                warning: try Self.color(named: "AppWarning"),
                danger: try Self.color(named: "AppDanger"))
    }

    // MARK: Labels on fills

    /// The rule `Theme.onAccent` exists for: the accent and the warning are
    /// both light, so a black label clears AA on each and a white one does not.
    func testBlackLabelClearsAAOnTheLightFills() throws {
        let c = try catalog()
        XCTAssertGreaterThanOrEqual(Self.contrast(.black, c.accent), 4.5)
        XCTAssertGreaterThanOrEqual(Self.contrast(.black, c.warning), 4.5)
        XCTAssertGreaterThanOrEqual(Self.contrast(.black, c.danger), 4.5)
    }

    /// Stated as the thing `Theme.onAccent` guards against, so that if the
    /// accent is ever darkened enough for white to work, this test says so
    /// and the rule can be revisited rather than silently outliving its reason.
    func testWhiteLabelWouldFailOnTheAccent() throws {
        let c = try catalog()
        XCTAssertLessThan(Self.contrast(.white, c.accent), 4.5)
    }

    // MARK: Text on the two surfaces

    /// Everything the shell writes in colour on the two page tones must clear
    /// AA for body text on both — the status colours are used as text in
    /// Files and on the game page, not only as badge fills.
    func testColouredTextClearsAAOnBothSurfaces() throws {
        let c = try catalog()
        for (name, color) in [("accent", c.accent), ("warning", c.warning),
                              ("danger", c.danger), ("secondary text", c.secondaryText)] {
            XCTAssertGreaterThanOrEqual(Self.contrast(color, c.background), 4.5, "\(name) on background")
            XCTAssertGreaterThanOrEqual(Self.contrast(color, c.surface), 4.5, "\(name) on surface")
        }
    }

    /// `Theme.onAccent` is the rule in code; this is it agreeing with the
    /// catalog it describes.
    func testThemeOnAccentIsBlack() {
        XCTAssertEqual(Theme.onAccent, .black)
    }
}
