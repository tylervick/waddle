import SwiftUI
import XCTest
@testable import Waddle

/// The import notice's text stays inside its background, however far it
/// wraps (issue #423).
///
/// The banner was a capsule round text with no line limit. A capsule's ends
/// are half-circles as tall as the banner, so from three lines up they cut
/// across the first and last lines, and at the largest accessibility size on
/// a closed iPhone Duo "Imported" and "Import Failed)" began outside the
/// background altogether, over the tile art.
///
/// This is a picture test because the claim is about a picture: no frame the
/// layout reports says whether a glyph lies over a curved background. The
/// banner is drawn twice on nothing, once as it ships and once with its text
/// clear, and the two are compared by coverage. Wherever the second drawing
/// is empty there is no background, so the first must be empty there too.
@MainActor
final class ImportNoticeBannerTests: XCTestCase {
    /// The longest notice the app posts: an adoption of two add-ons that ends
    /// with one failure, as the Duo sweep made it.
    private static let longest = "Imported sweep-patch, sweep-addon as add-ons. "
        + "Attach them from any game's page. · 1 failed (moved to Import Failed)"
    private static let oneLine = "Imported Sunlust"

    /// The width the overlay offers the banner: the window less the margin
    /// `ContentView` keeps on each side. The narrowest supported iPhone, the
    /// Duo's four windows, and an iPad.
    private static let windowWidths: [CGFloat] = [360, 466, 669, 678, 951, 1024]
    private static let scale: CGFloat = 2

    /// How much of each pixel a drawing covers, 0 to 255, and how bright
    /// the pixel is.
    private struct Coverage {
        let width: Int
        let height: Int
        let alpha: [UInt8]
        let red: [UInt8]

        subscript(x: Int, y: Int) -> UInt8 { alpha[y * width + x] }
        var size: CGSize { CGSize(width: width, height: height) }
    }

    /// Longer than any whole drawing of the banner takes (about 0.1 s each on
    /// CI's slowest leg) and shorter than the 2 s after which the renderer
    /// gives up waiting on itself and hands back what it has.
    private static let longestWholeDrawing: Duration = .milliseconds(1500)
    /// All the time the suite may spend on drawings it throws away, together.
    /// The slowest first pipeline build CI has logged is 46 s, starved on
    /// purpose. Per drawing rather than per suite, a runner on which every
    /// drawing was slow would have spent 90 s on each of the sweep's 72 cases and
    /// been cancelled at the leg's timeout with no failure to read.
    private static let redrawBudget: Duration = .seconds(90)

    /// Time spent so far, by every test of the suite, on drawings thrown away.
    private static var redrawSpent: Duration = .zero
    /// Set once the budget is spent: every drawing after it fails at once.
    private static var gaveUp: RendererNeverFinished?
    /// Set when the warm-up in `setUp()` could not finish a drawing.
    private static var warmUpFailure: RendererNeverFinished?

    private struct RendererNeverFinished: Error, CustomStringConvertible {
        let description: String
    }

    /// Draws one banner and throws it away before any test asks a drawing
    /// anything, so that whichever test runs first, its first drawing is not
    /// the one that builds the pipeline.
    ///
    /// The timing rule in `finishedDrawing` catches a read that waited out
    /// the renderer's 2 s, but not one that blocked until the build ended and
    /// came back unfinished in under 1.5 s. Only the drawings made while the
    /// pipeline builds can be that, and here they are all thrown away: the
    /// warm-up ends at the second drawing in a row under 1.5 s, which starts
    /// after the first has returned, and a read made during the build returns
    /// only once it has ended or after the 2 s the timing rule catches.
    override nonisolated class func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            let warmUp = ImportNoticeBanner(text: Self.longest)
                .foregroundStyle(Color.white)
                .environment(\.dynamicTypeSize, .accessibility5)
            do {
                for _ in 0..<2 {
                    _ = try Self.finishedDrawing(of: warmUp, width: 466 - Theme.Spacing.base * 2,
                                                 describedAs: "the warm-up")
                }
            } catch let failure as RendererNeverFinished {
                Self.warmUpFailure = failure
            } catch {
                Self.warmUpFailure = RendererNeverFinished(description: "the warm-up failed: \(error)")
            }
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if let failure = Self.warmUpFailure {
            throw RendererNeverFinished(description: "no drawing of the banner finished before the tests: "
                                        + failure.description)
        }
    }

    /// A drawing of `content` that the renderer finished, as RGBA bytes.
    ///
    /// The first drawing in a test process builds a Metal pipeline
    /// (`primitive_color`). On CI's simulators that has taken from half a
    /// second to 25 s. The `CGImage` the renderer returns is drawn only when
    /// its pixels are read, and a read made while the pipeline builds waits
    /// 2 s, logs "image provider … timed out while waiting for phase 6", and
    /// gives back pixels without the shapes still waiting on it, or blocks
    /// until the build ends with pixels just as incomplete. A read that took
    /// far longer than a whole one does is the only sign of it the renderer
    /// gives, so a slow drawing is thrown away and drawn again (issue #439,
    /// `docs/learnings/imagerenderer-hands-back-an-unfinished-drawing.md`).
    /// What a drawing is then asked is the same either way.
    private static func finishedDrawing(of content: some View, width: CGFloat,
                                        describedAs label: String) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        if let gaveUp {
            throw RendererNeverFinished(description: "not drawn at \(label): earlier, \(gaveUp.description)")
        }
        let clock = ContinuousClock()
        let started = clock.now
        var discarded = 0
        while true {
            let began = clock.now
            let renderer = ImageRenderer(content: content)
            renderer.scale = Self.scale
            renderer.proposedSize = ProposedViewSize(width: width, height: nil)
            guard let image = renderer.cgImage else {
                throw RendererNeverFinished(description: "the banner did not draw at \(label)")
            }
            // Reading the pixels is what draws them, so it is inside the time.
            var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let drew = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                return true
            }
            guard drew else { throw RendererNeverFinished(description: "no bitmap context at \(label)") }
            let took = clock.now - began
            if took < Self.longestWholeDrawing {
                if discarded > 0 {
                    NSLog("ImportNoticeBannerTests: %@", "\(discarded) unfinished drawing(s) of the banner at \(label) "
                          + "thrown away over \(clock.now - started) before one finished in \(took)")
                }
                return (image.width, image.height, rgba)
            }
            discarded += 1
            redrawSpent += took
            NSLog("ImportNoticeBannerTests: %@", "a drawing of the banner at \(label) took \(took); drawing it again")
            guard redrawSpent < Self.redrawBudget else {
                let failure = RendererNeverFinished(description: "the renderer took \(Self.longestWholeDrawing) "
                    + "or longer on drawings thrown away for \(redrawSpent) in this suite, the last \(discarded) "
                    + "of them of the banner at \(label)")
                gaveUp = failure
                throw failure
            }
        }
    }

    private func coverage(of text: String, textShown: Bool, windowWidth: CGFloat,
                          size: DynamicTypeSize) throws -> Coverage {
        // The banner sets no colour on its text, so it takes the one handed
        // down, and a clear one leaves the background and hairline alone.
        let banner = ImportNoticeBanner(text: text)
            .foregroundStyle(textShown ? Color.white : Color.clear)
            .environment(\.dynamicTypeSize, size)
        let drawing = try Self.finishedDrawing(of: banner, width: windowWidth - Theme.Spacing.base * 2,
                                               describedAs: "\(size), \(windowWidth) pt")
        let count = drawing.width * drawing.height
        return Coverage(width: drawing.width, height: drawing.height,
                        alpha: (0..<count).map { drawing.rgba[$0 * 4 + 3] },
                        red: (0..<count).map { drawing.rgba[$0 * 4] })
    }

    /// Pixels the text marks where there is no background at all.
    private func pixelsOutsideBackground(_ text: String, windowWidth: CGFloat,
                                         size: DynamicTypeSize) throws -> Int {
        let whole = try coverage(of: text, textShown: true, windowWidth: windowWidth, size: size)
        let background = try coverage(of: text, textShown: false, windowWidth: windowWidth, size: size)
        XCTAssertEqual(whole.size, background.size, "the text's colour changed the banner's size")
        // The text is white on a dark surface, so it shows in the red channel
        // where it lies over the background, which coverage alone cannot say.
        XCTAssertTrue(whole.red != background.red,
                      "clearing the text changed nothing, so this compares a drawing with itself")
        return zip(whole.alpha, background.alpha).reduce(0) { $0 + ($1.1 == 0 && $1.0 != 0 ? 1 : 0) }
    }

    func testEveryGlyphIsOverTheBackgroundAtEveryTextSizeAndWidth() throws {
        for size in DynamicTypeSize.allCases {
            for width in Self.windowWidths {
                // `try` outside the assertion: a renderer that gave up ends
                // the sweep here rather than once for each case left.
                let outside = try pixelsOutsideBackground(Self.longest, windowWidth: width, size: size)
                XCTAssertEqual(outside, 0, "text outside the banner's background at \(size) in a \(width) pt window")
            }
        }
    }

    /// The case the issue measured: eight lines on a closed Duo. It is in the
    /// sweep above; this pins that the sweep's hardest case is as hard as it
    /// is meant to be, since a renderer that ignored the text size would
    /// leave every case a one- or two-line banner and prove little.
    func testTheLargestTextSizeWrapsToManyLinesOnAClosedDuo() throws {
        let large = try coverage(of: Self.longest, textShown: true, windowWidth: 466, size: .large)
        let largest = try coverage(of: Self.longest, textShown: true, windowWidth: 466, size: .accessibility5)
        XCTAssertGreaterThan(largest.height, large.height * 4,
                             "accessibility5 is \(largest.height) px tall against \(large.height) px at large")
    }

    /// The same corner on one line and on many: the outline does not follow
    /// the line count.
    func testCornersAreTheSameOnOneLineAndOnMany() throws {
        let short = try coverage(of: Self.oneLine, textShown: false, windowWidth: 466, size: .large)
        let tall = try coverage(of: Self.longest, textShown: false, windowWidth: 466, size: .accessibility5)
        let corner = Int(Theme.cornerRadius * Self.scale)
        XCTAssertGreaterThan(tall.height, short.height * 4, "the long notice did not wrap")
        XCTAssertGreaterThan(min(short.width, short.height), corner, "the short banner is smaller than a corner")
        XCTAssertEqual(short[0, 0], 0, "the corner is square, so this compares nothing")
        for y in 0..<corner {
            // Not exactly equal: a continuous corner of this radius wants a
            // little more than half of a 44 pt banner to itself, so on one
            // line it is drawn a shade tighter (11 of 255 at one edge pixel,
            // measured). A capsule's corner differs by full coverage.
            for x in 0..<corner where abs(Int(short[x, y]) - Int(tall[x, y])) > 32 {
                return XCTFail("the corner differs at \(x),\(y): \(short[x, y]) on one line, "
                               + "\(tall[x, y]) on \(tall.height / Int(Self.scale)) pt of text")
            }
        }
    }

    /// It is dismissed by a tap, so it is never shorter than a tap target.
    func testAOneLineBannerIsATapTargetTall() throws {
        let short = try coverage(of: Self.oneLine, textShown: false, windowWidth: 466, size: .xSmall)
        XCTAssertGreaterThanOrEqual(CGFloat(short.height) / Self.scale, Theme.minimumTapTarget)
    }
}
