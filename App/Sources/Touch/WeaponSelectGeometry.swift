import CoreGraphics

/// Where the weapon-select grid sits over the game picture. Pure, like
/// `MenuTouchRouter`, so `WaddleTests` pins the layout without UIKit.
///
/// Every value is a fraction of the picture rect, not of the screen: the
/// picture is letterboxed, and the grid must follow it. The grid mirrors the
/// predecessor app's 480x320 layout: a 3x3 of 120x80 cells on a 160x88
/// pitch, which leaves 40-wide column gaps (20 at each edge) and 8-tall row
/// gaps, and ends 64/320 above the picture's bottom so the status bar stays
/// clear. The hotspot is the bottom-centre patch that opens the grid.
struct WeaponSelectGeometry: Equatable {
    static let cellCount = 9

    private static let columns = 3
    private static let refWidth: CGFloat = 480
    private static let refHeight: CGFloat = 320

    let pictureRect: CGRect
    let hotspot: CGRect

    init(pictureRect: CGRect) {
        self.pictureRect = pictureRect
        let w = pictureRect.width / 6
        let h = pictureRect.height / 4
        hotspot = CGRect(x: pictureRect.midX - w / 2, y: pictureRect.maxY - h,
                         width: w, height: h)
    }

    /// Frame of cell `index` (0..<9), column `index % 3`, row `index / 3`.
    func cellFrame(_ index: Int) -> CGRect {
        let col = CGFloat(index % Self.columns)
        let row = CGFloat(index / Self.columns)
        return CGRect(
            x: pictureRect.minX + (col * 160 + 20) / Self.refWidth * pictureRect.width,
            y: pictureRect.minY + row * 88 / Self.refHeight * pictureRect.height,
            width: 120 / Self.refWidth * pictureRect.width,
            height: 80 / Self.refHeight * pictureRect.height)
    }

    /// The cell under `point`, or nil in a gap or outside the grid.
    func cell(at point: CGPoint) -> Int? {
        (0..<Self.cellCount).first { cellFrame($0).contains(point) }
    }
}
