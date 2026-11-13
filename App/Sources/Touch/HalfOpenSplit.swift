import CoreGraphics

/// One "division" region as UIKit reports it for a view on a folding
/// display (`UIView.reservedRegions(kind: .division)`, iOS 27.1): the band
/// across the fold where the system says content should part in two.
///
/// Measured on the iPhone Duo simulator on 2026-11-13: a band 40 pt thick
/// centred on the fold, its `frame` already including the 20 pt margin the
/// system asks interactive content to keep on each side. It is reported in
/// every open pose and is `isActive` only while the hinge is partly open.
struct FoldDivision: Equatable {
    /// In the overlay's coordinates, margins included.
    var frame: CGRect
    var isActive: Bool
}

/// The half-open play layout (issue #373): the game above the fold, the
/// touch controls below it. Pure, like `TouchOverlayLayout`: what the system
/// reported in, two rects out.
///
/// An iPhone Duo standing half open on a table has an upright half and a
/// flat one. Apple's "Design for iPhone Duo" allows one pose-specific
/// layout for exactly this: media on the upright half, controls on the flat
/// one, with the same controls in the same hierarchy. Nothing here adds or
/// removes a control; `TouchOverlayLayout` keeps their sizes and only moves
/// what would otherwise sit above the fold.
struct HalfOpenSplit: Equatable {
    /// Where the engine may draw the picture: the window above the band.
    let pictureArea: CGRect
    /// Where every control goes: the window below the band.
    let controlsArea: CGRect
    /// The band itself. No control's frame may touch it.
    let crease: CGRect

    /// How much of the window's height each side must keep for the split to
    /// be worth making. A band reported hard against an edge would leave a
    /// sliver for the picture or for the controls; the Duo's is at the
    /// middle, so this never decides anything there.
    static let minimumShare: CGFloat = 0.25

    /// The split for what the system reports, or `nil` for the normal
    /// layout.
    ///
    /// Both signals are required, and both come from the system: the hinge
    /// is partly open, and an active division crosses the window from side
    /// to side. The window's size says nothing; it is 669x951 flat and
    /// 669x951 half open. The hinge alone is not enough either, because it
    /// does not say which way the fold runs: held like a book the same
    /// hinge reading comes with a division from top to bottom, and there
    /// the picture stays where it is. And the division's `isActive` trails
    /// the hinge by about a third of a second on the way in and outlasts it
    /// by a frame on the way out, so each is checked.
    init?(bounds: CGRect, hingePartiallyOpen: Bool, divisions: [FoldDivision]) {
        guard hingePartiallyOpen, bounds.width > 0, bounds.height > 0 else { return nil }
        let edgeSlack: CGFloat = 0.5
        let across = divisions.first { division in
            division.isActive
                && division.frame.minX <= bounds.minX + edgeSlack
                && division.frame.maxX >= bounds.maxX - edgeSlack
                && division.frame.minY > bounds.minY
                && division.frame.maxY < bounds.maxY
        }
        guard let crease = across?.frame else { return nil }
        let above = CGRect(x: bounds.minX, y: bounds.minY,
                           width: bounds.width, height: crease.minY - bounds.minY)
        let below = CGRect(x: bounds.minX, y: crease.maxY,
                           width: bounds.width, height: bounds.maxY - crease.maxY)
        let least = bounds.height * Self.minimumShare
        guard above.height >= least, below.height >= least else { return nil }
        self.pictureArea = above
        self.controlsArea = below
        self.crease = CGRect(x: bounds.minX, y: crease.minY,
                             width: bounds.width, height: crease.height)
    }
}
