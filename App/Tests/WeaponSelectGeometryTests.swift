import XCTest
@testable import Waddle

/// The weapon-select grid is laid out as fractions of the game's picture
/// rect, so it tracks the letterboxed picture on any screen. Pure, so the
/// proportions are pinned without UIKit.
final class WeaponSelectGeometryTests: XCTestCase {
    private func assertRect(_ r: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.minX, x, accuracy: 0.01, "x", file: file, line: line)
        XCTAssertEqual(r.minY, y, accuracy: 0.01, "y", file: file, line: line)
        XCTAssertEqual(r.width, w, accuracy: 0.01, "width", file: file, line: line)
        XCTAssertEqual(r.height, h, accuracy: 0.01, "height", file: file, line: line)
    }

    func testReferencePicture() {
        let g = WeaponSelectGeometry(pictureRect: CGRect(x: 0, y: 0, width: 480, height: 320))
        assertRect(g.cellFrame(0), 20, 0, 120, 80)
        assertRect(g.cellFrame(4), 180, 88, 120, 80)
        assertRect(g.cellFrame(8), 340, 176, 120, 80)
        assertRect(g.hotspot, 200, 240, 80, 80)
    }

    func testLetterboxedPictureIsOffsetAndScaled() {
        let g = WeaponSelectGeometry(pictureRect: CGRect(x: 0, y: 100, width: 400, height: 250))
        assertRect(g.cellFrame(8), 283.33, 237.5, 100, 62.5)
        assertRect(g.hotspot, 166.67, 287.5, 66.67, 62.5)
    }

    func testPointToCell() {
        let g = WeaponSelectGeometry(pictureRect: CGRect(x: 0, y: 0, width: 480, height: 320))
        XCTAssertEqual(g.cell(at: CGPoint(x: 80, y: 40)), 0)
        XCTAssertEqual(g.cell(at: CGPoint(x: 240, y: 200)), 7)
        XCTAssertNil(g.cell(at: CGPoint(x: 150, y: 40)))   // column gap
        XCTAssertNil(g.cell(at: CGPoint(x: 80, y: 84)))    // row gap
        XCTAssertNil(g.cell(at: CGPoint(x: 240, y: 300)))  // status bar
    }

    func testSmallAndOddPicturesStayInsideAndDisjoint() {
        let pictures = [
            CGRect(x: 0, y: 0, width: 160, height: 100),
            CGRect(x: 37, y: 12, width: 402, height: 251),
            CGRect(x: 0, y: 0, width: 1366, height: 854),
        ]
        for p in pictures {
            let g = WeaponSelectGeometry(pictureRect: p)
            XCTAssertTrue(p.contains(g.hotspot), "hotspot inside \(p)")
            let frames = (0..<WeaponSelectGeometry.cellCount).map { g.cellFrame($0) }
            for (i, f) in frames.enumerated() {
                XCTAssertTrue(p.contains(f), "cell \(i) inside \(p)")
                for j in (i + 1)..<frames.count {
                    XCTAssertFalse(f.intersects(frames[j]), "cells \(i) and \(j) overlap in \(p)")
                }
            }
        }
    }
}
