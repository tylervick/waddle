import UIKit

/// The circular controls the overlay lays out. Raw values are the
/// accessibility identifiers `TouchOverlayView` assigns, so the view can map
/// its own buttons onto this table and UI tests keep addressing them by the
/// same names.
enum TouchOverlayControl: String, CaseIterable {
    case fire = "fireButton"
    case use = "useButton"
    case weaponPrev = "weaponPrevButton"
    case weaponNext = "weaponNextButton"
    case automap = "automapButton"
    case menu = "menuButton"

    /// Drawn diameter at scale 1.0 — the sizes tuned on-device for the
    /// phone. FIRE is biggest because it is held down constantly.
    var baseDiameter: CGFloat {
        switch self {
        case .fire: return 84
        case .use: return 64
        case .weaponPrev, .weaponNext, .automap, .menu: return 48
        }
    }
}

/// Pure geometry for the in-game touch overlay: bounds in, control frames
/// out. No UIKit views, no SDL, no engine — same shape as `TouchStickModel`
/// and `KeyboardGate`, and testable the same way.
///
/// ## Why a scale factor at all
///
/// Every offset used to be a literal point value measured on a phone
/// (`x: b.maxX - inset.right - 160`), so the overlay was the same physical
/// size on a 13" iPad as on an iPhone: proportionally tiny, and jammed into
/// a corner on top of Doom's status bar. The predecessor this app replaces
/// solved it by authoring controls in a virtual 480x320 landscape space and
/// scaling into the real screen (`SetHudSpot`, DOOM-iOS `code/iphone/hud.c`),
/// which is the model reproduced here.
///
/// The one deliberate difference: the reference is *this* app's own shipped
/// phone geometry rather than that 480x320 space, so the reference device
/// resolves to exactly 1.0 and every base value below is literally the
/// already-device-tuned iPhone number. Nothing about the phone layout had to
/// move to make the iPad work.
struct TouchOverlayLayout {
    /// Safe-area dimensions of the tuning device (iPhone 17 Pro), from its
    /// CoreSimulator profile: 1206x2622 px at scale 3 = 402x874 pt. Read
    /// from `mainScreenWidth`/`mainScreenHeight`/`mainScreenScale`, not
    /// recalled — if this pair is ever wrong, every device including the
    /// phone silently lays out at the wrong size.
    static let referenceShortSide: CGFloat = 402
    static let referenceLongSide: CGFloat = 874

    /// Floor and ceiling on the scale. The floor matters for iPadOS
    /// "Windowed Apps" multitasking, where the window can be dragged far
    /// below any phone size; the ceiling keeps a hypothetical very large
    /// display from producing comically large controls.
    static let minScale: CGFloat = 0.5
    static let maxScale: CGFloat = 1.75

    /// Doom's status bar (ammo/health/face/armor) as a fraction of the
    /// picture's height: it is drawn 32 rows tall in a 200-row frame — 16%.
    /// The predecessor reserved a near-identical band (`BOTTOM = 320 - 44` =
    /// 13.75%, DOOM-iOS `hud.c:91`).
    ///
    /// Used two ways. Without a picture rect it is a fraction of the *short*
    /// side, reserved along the window's bottom edge: in landscape the game
    /// fills the window and that is the real bar, and it is the arrangement
    /// every phone layout was tuned against. With a picture rect
    /// (`WoofIOS_GetPictureRect`) it is the bottom 16% of the picture the
    /// engine is actually drawing, wherever in the window that is — see
    /// `statusBarBand`.
    static let statusBarFraction: CGFloat = 0.16

    /// Multiplier applied to every size and offset. 1.0 on the reference
    /// device, ~1.57 on a 13" iPad, ~1.38 on an 11" iPad, below 1.0 in a
    /// small iPadOS window.
    let scale: CGFloat

    /// Movement/turn stick radius, scaled. 60 pt on the reference device.
    let stickRadius: CGFloat

    /// Radius of the knob drawn inside the stick base, scaled. 26 pt on the
    /// reference device.
    let knobRadius: CGFloat

    /// Height of the band kept clear along the window's bottom edge when
    /// the bar is assumed to be there: `statusBarFraction` of the short side.
    let statusBarReserve: CGFloat

    /// Where Doom's status bar is, in overlay coordinates: the bottom 16% of
    /// the picture when the layout was given one, and otherwise the
    /// window-bottom reserve. The bottom cluster's default frames never
    /// overlap it.
    let statusBarBand: CGRect

    /// The player's own positions (issue #115): per-control offsets from
    /// the default center in reference points, applied by `frame(for:)` and
    /// clamped inside the window. `.none` is the shipped arrangement.
    let overrides: TouchOverlayLayoutOverrides

    private let usable: CGRect
    private let topRowY: CGFloat
    private let bottomLimit: CGFloat

    /// - Parameter pictureRect: the rect the engine is drawing the game
    ///   into, in overlay coordinates, when it is known. `nil` keeps the
    ///   window-bottom reserve and nothing else.
    init(bounds: CGRect, safeAreaInsets: UIEdgeInsets, hudReserve: CGFloat,
         overrides: TouchOverlayLayoutOverrides = .none, pictureRect: CGRect? = nil) {
        let usable = bounds.inset(by: safeAreaInsets)

        // Short/long rather than width/height: a rotation must not resize
        // the controls under the player's thumbs mid-session, and Doom on a
        // phone is played in both orientations.
        let short = min(usable.width, usable.height)
        let long = max(usable.width, usable.height)

        // min() of the two ratios, not max() and not per-axis: the overlay
        // must fit the *tighter* dimension, and scaling each axis separately
        // would stretch round buttons into ellipses.
        let raw = min(short / Self.referenceShortSide, long / Self.referenceLongSide)
        let scale = Swift.min(Swift.max(raw, Self.minScale), Self.maxScale)

        self.scale = scale
        self.overrides = overrides
        self.usable = usable
        self.stickRadius = 60 * scale
        self.knobRadius = 26 * scale
        self.statusBarReserve = short * Self.statusBarFraction
        self.topRowY = usable.minY + hudReserve

        let windowLimit = usable.maxY - statusBarReserve
        if let picture = pictureRect, picture.width > 0, picture.height > 0 {
            let bandHeight = picture.height * Self.statusBarFraction
            let band = CGRect(x: picture.minX, y: picture.maxY - bandHeight,
                              width: picture.width, height: bandHeight)
            self.statusBarBand = band
            self.bottomLimit = Self.bottomLimit(clearing: band, windowLimit: windowLimit,
                                                usable: usable, scale: scale)
        } else {
            self.statusBarBand = CGRect(x: usable.minX, y: windowLimit,
                                        width: usable.width, height: statusBarReserve)
            self.bottomLimit = windowLimit
        }
    }

    /// Gap left between the picture's bottom edge and the cluster when the
    /// cluster moves below the picture, at scale 1.0.
    static let pictureClearance: CGFloat = 8

    /// How far the bottom cluster reaches above its limit line at scale 1.0:
    /// the weapon pair's centre (116) plus its radius (24).
    static let bottomClusterBaseHeight: CGFloat = 140

    /// The line FIRE and USE stand on, given where the status bar really is.
    ///
    /// The window-bottom line is kept whenever the cluster it produces is
    /// already clear of the bar. That is every phone in both orientations and
    /// any window the picture fills, so none of those layouts move: with a
    /// tall letterbox the cluster sits well below the picture, and with the
    /// picture filling the window the reserve is the bar.
    ///
    /// It is not clear in a letterboxed window close to square. An iPhone
    /// Duo's two portrait poses and an iPad in portrait put the picture's
    /// bottom edge inside the cluster, and the weapon pair lands on the bar
    /// (issue 351). Then the cluster goes wholly below the picture if the
    /// window has the room, which keeps it out of the game entirely, and
    /// otherwise wholly above the bar, over the 3D view, which is where it
    /// sits whenever the picture fills the window.
    private static func bottomLimit(clearing band: CGRect, windowLimit: CGFloat,
                                    usable: CGRect, scale: CGFloat) -> CGFloat {
        let collides = bottomCluster.contains { control in
            overlaps(clusterFrame(for: control, right: usable.maxX,
                                  bottomLimit: windowLimit, scale: scale), band)
        }
        guard collides else { return windowLimit }
        let below = band.maxY + (pictureClearance + bottomClusterBaseHeight) * scale
        return below <= usable.maxY ? below : band.minY
    }

    /// Overlap by more than a hundredth of a point. Rects that only share an
    /// edge do not count: FIRE stands exactly on the bar's top edge whenever
    /// the picture fills the window, and the two sides of that comparison
    /// are computed by different routes, so an exact test would call a
    /// rounding difference in the last bit a collision.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let slack: CGFloat = 0.01
        return a.minX < b.maxX - slack && b.minX < a.maxX - slack
            && a.minY < b.maxY - slack && b.minY < a.maxY - slack
    }

    /// The picture rect to assume before the engine reports one, and in the
    /// layout editor, which has no session: the window's own shape clamped
    /// to the aspects the engine renders (4:3 up to 3.6:1, `i_video.c`
    /// `CurrentAspectRatio`), fitted and centred as SDL's letterbox does.
    /// A live session can differ — its aspect is fixed when it starts — which
    /// is why the session asks the engine instead.
    static func predictedPictureRect(in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        let aspect = Swift.min(Swift.max(bounds.width / bounds.height, 4.0 / 3.0), 3.6)
        var size = CGSize(width: bounds.width, height: bounds.width / aspect)
        if size.height > bounds.height {
            size = CGSize(width: bounds.height * aspect, height: bounds.height)
        }
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The controls that stand on `bottomLimit`.
    private static let bottomCluster: [TouchOverlayControl] = [.fire, .use, .weaponPrev, .weaponNext]

    /// A bottom-cluster control's default frame for a given limit line.
    /// `defaultFrame(for:)` and the status-bar check both go through this, so
    /// the check measures the frames that would actually be drawn.
    private static func clusterFrame(for control: TouchOverlayControl, right: CGFloat,
                                     bottomLimit: CGFloat, scale s: CGFloat) -> CGRect {
        let center: CGPoint
        switch control {
        case .fire:
            // Sits on the reserve line: its own radius up from `bottomLimit`.
            center = CGPoint(x: right - 70 * s, y: bottomLimit - 42 * s)
        case .use:
            center = CGPoint(x: right - 160 * s, y: bottomLimit - 32 * s)
        case .weaponNext:
            center = CGPoint(x: right - 46 * s, y: bottomLimit - 116 * s)
        case .weaponPrev:
            center = CGPoint(x: right - 102 * s, y: bottomLimit - 116 * s)
        case .automap, .menu:
            preconditionFailure("\(control) is not in the bottom cluster")
        }
        let diameter = control.baseDiameter * s
        return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                      width: diameter, height: diameter)
    }

    /// Where `control` belongs, in overlay coordinates: its default frame,
    /// moved by the player's offset (times `scale`) when there is one, and
    /// then clamped so the whole circle stays inside the usable rect and
    /// below the debug-HUD strip. The clamp is what lets a layout saved in
    /// landscape, or on an iPad, install in portrait or in a small iPadOS
    /// window without a button leaving the screen (issue #115's hard
    /// requirement, and issue #52's containment property extended to every
    /// position a user can persist). The size never changes.
    func frame(for control: TouchOverlayControl) -> CGRect {
        let base = defaultFrame(for: control)
        guard let offset = overrides[control] else { return base }
        let wanted = CGPoint(x: base.midX + offset.x * scale, y: base.midY + offset.y * scale)
        let center = clampedCenter(wanted, diameter: base.width)
        return CGRect(x: center.x - base.width / 2, y: center.y - base.height / 2,
                      width: base.width, height: base.height)
    }

    /// The offset (reference points) that puts `control`'s center at
    /// `center`, already clamped: what the layout editor stores while a
    /// button is dragged, so the persisted position is the one the player
    /// saw and `frame(for:)` reproduces it exactly. Placing a control at its
    /// default center yields zero, so "dragged back" and "never moved" are
    /// the same stored state.
    func clampedOverrideOffset(placing control: TouchOverlayControl, at center: CGPoint) -> CGPoint {
        let base = defaultFrame(for: control)
        let clamped = clampedCenter(center, diameter: base.width)
        return CGPoint(x: (clamped.x - base.midX) / scale, y: (clamped.y - base.midY) / scale)
    }

    /// `center` moved the least distance that keeps a circle of `diameter`
    /// inside the usable rect and below the HUD reserve. A window too small
    /// for the circle centers it on that axis rather than inverting the range.
    private func clampedCenter(_ center: CGPoint, diameter: CGFloat) -> CGPoint {
        let r = diameter / 2
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
            lo > hi ? (lo + hi) / 2 : Swift.min(Swift.max(v, lo), hi)
        }
        return CGPoint(x: clamp(center.x, usable.minX + r, usable.maxX - r),
                       y: clamp(center.y, topRowY + r, usable.maxY - r))
    }

    /// Where `control` belongs with nothing moved, in overlay coordinates.
    ///
    /// ## The arrangement
    ///
    /// Two clusters, plus two corners:
    ///
    /// - **Bottom right, in the thumb arc** — FIRE, USE inboard of it, and
    ///   the weapon-cycle pair stacked above FIRE. Weapon switching happens
    ///   mid-combat, so it has to be reachable without regripping. It used
    ///   to live in the two *top* corners, which on a 13" iPad is a
    ///   two-handed stretch across the whole screen.
    /// - **Bottom left** — the movement stick, which has no fixed frame: it
    ///   is drawn wherever the finger lands (`TouchOverlayView.drawStick`).
    /// - **Top corners** — MAP and MENU. Deliberately outside the thumb arc:
    ///   both pause the action, and reaching for them is not a cost during
    ///   play. This is also where the predecessor put them (DOOM-iOS
    ///   `hud.c` scheme 0: map at 24,24 and menu at 456,24 of 480x320).
    ///
    /// Offsets are the phone-tuned values multiplied by `scale`, so the
    /// clusters keep their shape and spacing at every size.
    func defaultFrame(for control: TouchOverlayControl) -> CGRect {
        let s = scale
        let center: CGPoint
        switch control {
        case .fire, .use, .weaponNext, .weaponPrev:
            return Self.clusterFrame(for: control, right: usable.maxX,
                                     bottomLimit: bottomLimit, scale: s)
        case .automap:
            center = CGPoint(x: usable.minX + 40 * s, y: topRowY + 32 * s)
        case .menu:
            center = CGPoint(x: usable.maxX - 40 * s, y: topRowY + 32 * s)
        }

        let diameter = control.baseDiameter * s
        return CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                      width: diameter, height: diameter)
    }

    /// Diameter of the Yes/No prompt buttons at scale 1.0: USE's, since
    /// they answer the same kind of one-shot question USE confirms.
    static let promptButtonBaseDiameter: CGFloat = 64

    /// Where the Yes/No buttons go while the engine shows a Y/N prompt:
    /// side by side in the top band, centred between MAP and ≡, No on the
    /// left and Yes on the right as iOS orders them. The top band rather
    /// than the bottom one because USE's default centre is 160 pt in from
    /// the right edge, which in portrait is exactly where a centred bottom
    /// pair would sit. Not a `TouchOverlayControl`: they are transient, and
    /// the layout editor must not offer to move them.
    func promptButtonFrames() -> PromptButtonFrames {
        let s = scale
        let diameter = Self.promptButtonBaseDiameter * s
        let y = topRowY + 36 * s
        let mid = usable.midX
        func frame(centeredAt x: CGFloat) -> CGRect {
            CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter)
        }
        return PromptButtonFrames(no: frame(centeredAt: mid - 40 * s),
                                  yes: frame(centeredAt: mid + 40 * s))
    }
}

/// The two prompt-button frames, in overlay coordinates.
struct PromptButtonFrames: Equatable {
    let no: CGRect
    let yes: CGRect
}
