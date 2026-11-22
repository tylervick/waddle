import SwiftUI
import UIKit
import XCTest
@testable import Waddle

/// Issue #458: a tile title that the one-line rule declared fitting was cut.
///
/// On an iPhone 17e in landscape at `accessibility-extra-extra-large` the
/// tile's line is 329 pt and "Freedoom Phase 1" read "Freedoom Phase…".
/// `PlayableTileLayout.oneLineTitleMinimumWidth` took 0.85 of the title's
/// full width (327.6 pt) as what the shrunk title needs, so the one line was
/// offered. But type is not drawn in proportion to its size: set at 0.85 of
/// its size the title is 328.9 pt by `UIFont`, and SwiftUI drew it whole
/// only from a 329.5 pt line. In a 329 pt line the one-line `Text` shrank as
/// far as it may and truncated.
///
/// Arithmetic already said the title fits, so the cases here draw the real
/// title (`PlayableTileTitle`) in a line of a chosen width and look at the
/// picture. The bundled names have no descenders, so the bottom line of ink
/// is cap height to baseline, and its last glyph is the digit when the name
/// is whole and the ellipsis's three low dots when it is cut.
@MainActor
final class TileTitleFitTests: XCTestCase {

    private static let bundled = ["Freedoom Phase 1", "Freedoom Phase 2"]
    private static let scale: CGFloat = 3

    /// Every size above the default, where the title may take a second line
    /// and the one-line rule is what decides between them.
    private static let largerSizes = DynamicTypeSize.allCases.filter { $0 > .large }

    /// Whether the last glyph of the title's bottom line stands as tall as
    /// the line: the digit, not an ellipsis.
    private func endsWhole(_ name: String, line: CGFloat, _ size: DynamicTypeSize) throws -> Bool {
        try endsWhole(drawing: AnyView(PlayableTileTitle(name: name)), line: line, size)
    }

    private func endsWhole(drawing view: AnyView, line: CGFloat, _ size: DynamicTypeSize) throws -> Bool {
        let title = view
            .foregroundStyle(.white)
            .frame(width: line, alignment: .leading)
            .environment(\.dynamicTypeSize, size)
        let renderer = ImageRenderer(content: title)
        renderer.scale = Self.scale
        let image = try XCTUnwrap(renderer.cgImage, "the title did not draw at \(size) in \(line)")
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        func inked(_ x: Int, _ y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] > 64 }
        let rows = (0..<height).map { y in (0..<width).contains { inked($0, y) } }

        // The bottom band of inked rows is the last line.
        guard let bottom = rows.lastIndex(of: true) else { return false }
        var top = bottom
        while top > 0, rows[top - 1] { top -= 1 }
        let band = top...bottom

        // The last glyph: the rightmost inked column in the band, and the
        // columns of ink touching it.
        let inkedColumn = { (x: Int) in band.contains { inked(x, $0) } }
        guard let right = (0..<width).last(where: inkedColumn) else { return false }
        var left = right
        while left > 0, inkedColumn(left - 1) { left -= 1 }
        let glyphRows = band.filter { y in (left...right).contains { inked($0, y) } }
        guard let glyphTop = glyphRows.first, let glyphBottom = glyphRows.last else { return false }
        return CGFloat(glyphBottom - glyphTop + 1) > CGFloat(band.count) * 0.6
    }

    // MARK: The issue's window

    /// The 17e's landscape tile at `accessibility-extra-extra-large`: both
    /// bundled titles are whole.
    func testBothBundledTitlesAreWholeInTheIssuesTile() throws {
        for name in Self.bundled {
            XCTAssertTrue(try endsWhole(name, line: 329, .accessibility4), "\(name) is cut")
        }
    }

    /// The check can tell: the one-line `Text` the tile offered there, on
    /// its own in the same line, is the cut the issue saw. This is what the
    /// title drew before the fix.
    func testTheOneLineTextAloneIsCutInTheIssuesTile() throws {
        let oneLine = Text("Freedoom Phase 1")
            .font(Theme.Typography.tileTitle)
            .lineLimit(1)
            .minimumScaleFactor(PlayableTileLayout.titleMinimumScaleFactor)
        XCTAssertFalse(try endsWhole(drawing: AnyView(oneLine), line: 329, .accessibility4))
    }

    // MARK: Every size

    /// At every size above the default, in every line from a point and a
    /// half under the rule's threshold to a point and a half over it, in
    /// thirds of a point, both bundled titles are whole, on one line or two.
    /// The threshold is where the rule changes its mind, so it is where a
    /// wrong rule cuts.
    func testTitlesAreWholeEitherSideOfTheOneLineThreshold() throws {
        for size in Self.largerSizes {
            for name in Self.bundled {
                let threshold = PlayableTileLayout.oneLineTitleMinimumWidth(
                    shrunkWidth: PlayableTileTitle.shrunkWidth(of: name, at: size))
                for step in -4...4 {
                    let line = threshold + CGFloat(step) / 3
                    XCTAssertTrue(try endsWhole(name, line: line, size),
                                  "\(name) is cut at \(size) in \(line) (threshold \(threshold))")
                }
            }
        }
    }

    /// And within a point either side of the title's full width, at every
    /// size: there it fits one line without shrinking, or nearly so.
    func testTitlesAreWholeWithinAPointOfTheirFullWidth() throws {
        for size in DynamicTypeSize.allCases {
            for name in Self.bundled {
                let font = UIFont.preferredFont(
                    forTextStyle: Theme.Typography.tileTitleStyle,
                    compatibleWith: UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(size)))
                let full = (name as NSString).size(withAttributes: [.font: font]).width
                for step in -3...3 {
                    let line = full + CGFloat(step) / 3
                    XCTAssertTrue(try endsWhole(name, line: line, size),
                                  "\(name) is cut at \(size) in \(line) (full width \(full))")
                }
            }
        }
    }
}
