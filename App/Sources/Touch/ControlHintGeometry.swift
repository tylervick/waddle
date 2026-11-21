import CoreGraphics

/// Where the overlay's control hints sit (issue #392). Pure, like
/// `WeaponRingGeometry`, so `WaddleTests` pins the layout without UIKit.
///
/// The Weapons hint is the weapon zone itself, taken from the installed
/// style's own geometry so the two cannot drift apart: the ring's hotspot
/// disc, or the grid's hotspot rectangle. Move and Aim are stick-sized
/// circles in the middle of the two columns `TouchTrackRouter` splits the
/// overlay into, the stick's and the drag-turn's; whether they are shown at
/// all is `ControlHintModel`'s call, not this type's.
struct ControlHintGeometry: Equatable {
    enum WeaponsShape: Equatable {
        /// The ring's hotspot: this disc, cut off where `weaponsFrame` ends
        /// (the frame is the disc's bounding box clipped to the picture).
        case disc(center: CGPoint, radius: CGFloat)
        /// The grid's hotspot: all of `weaponsFrame`.
        case rectangle
    }

    /// The weapon zone's frame, in the overlay's coordinates: what the
    /// `weaponSelectHotspot` view is laid out to.
    let weaponsFrame: CGRect
    let weaponsShape: WeaponsShape
    let moveFrame: CGRect
    let aimFrame: CGRect

    /// - Parameters:
    ///   - pictureRect: the rect the game is drawn into, as the weapon
    ///     selector's own geometry takes it.
    ///   - controlsArea: the part of the overlay a stick or turn may start
    ///     in when the device stands half open (`HalfOpenSplit`); nil is the
    ///     whole overlay.
    ///   - stickRadius: `TouchOverlayLayout.stickRadius`, so Move and Aim
    ///     are the size of the stick they name.
    init(style: WeaponSelectorStyle, pictureRect: CGRect, bounds: CGRect,
         controlsArea: CGRect? = nil, stickRadius: CGFloat) {
        switch style {
        case .ring:
            let ring = WeaponRingGeometry(pictureRect: pictureRect)
            weaponsFrame = ring.hotspot
            weaponsShape = .disc(center: ring.center, radius: ring.innerRadius)
        case .grid:
            weaponsFrame = WeaponSelectGeometry(pictureRect: pictureRect).hotspot
            weaponsShape = .rectangle
        }
        let area = controlsArea ?? bounds
        let split = bounds.minX + bounds.width * TouchTrackRouter.stickColumnFraction
        func circle(from left: CGFloat, to right: CGFloat) -> CGRect {
            CGRect(x: (left + right) / 2 - stickRadius, y: area.midY - stickRadius,
                   width: 2 * stickRadius, height: 2 * stickRadius)
        }
        moveFrame = circle(from: bounds.minX, to: split)
        aimFrame = circle(from: split, to: bounds.maxX)
    }
}
