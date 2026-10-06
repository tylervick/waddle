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

    /// Fraction of the short side kept clear at the bottom for Doom's own
    /// status bar (ammo/health/face/armor). Doom draws it 32 rows tall in a
    /// 200-row frame — 16%. The predecessor reserved a near-identical band
    /// (`BOTTOM = 320 - 44` = 13.75%, DOOM-iOS `hud.c:91`).
    ///
    /// Deliberately the *short* side, not `bounds.height`: in landscape the
    /// game fills the window and 16% of height is the real bar, while in
    /// portrait the game letterboxes and 16% of a tall window would reserve
    /// far more than the bar occupies. Exactly locating the bar needs the
    /// engine's letterboxed viewport rect, and there is no `WoofIOS_` call
    /// that exposes it (see `Engine/woof/src/woof_ios.h`) — this
    /// approximation is why FIRE no longer sits on top of the bar, and a
    /// viewport API would let it become exact.
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

    /// Height of the band kept clear at the bottom for Doom's status bar.
    let statusBarReserve: CGFloat

    /// The player's own positions (issue #115): per-control offsets from
    /// the default center in reference points, applied by `frame(for:)` and
    /// clamped inside the window. `.none` is the shipped arrangement.
    let overrides: TouchOverlayLayoutOverrides

    private let usable: CGRect
    private let topRowY: CGFloat
    private let bottomLimit: CGFloat

    init(bounds: CGRect, safeAreaInsets: UIEdgeInsets, hudReserve: CGFloat,
         overrides: TouchOverlayLayoutOverrides = .none) {
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
        self.bottomLimit = usable.maxY - statusBarReserve
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
        let diameter = control.baseDiameter * s
        let left = usable.minX, right = usable.maxX

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
        case .automap:
            center = CGPoint(x: left + 40 * s, y: topRowY + 32 * s)
        case .menu:
            center = CGPoint(x: right - 40 * s, y: topRowY + 32 * s)
        }

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
