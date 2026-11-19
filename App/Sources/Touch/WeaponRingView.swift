import UIKit

/// The weapon-select ring's drawing: seven wedge panels fanned over the
/// middle of the status bar, a thin gap between them, each with its weapon's
/// sprite upright at mid-radius. Flat fills in the grid's palette and
/// nearest-neighbour pixels so it reads as part of the game: no blur, no
/// system materials, no name labels.
///
/// Drawing only. `isUserInteractionEnabled` is false on the view and every
/// wedge, so touches fall through to the overlay, which owns them and drives
/// `WeaponRingModel`. Geometry is in this view's coordinate space, so the
/// overlay lays this view out to fill itself.
///
/// The wedges are accessibility elements only while the view is shown. A
/// hidden view's subviews are already outside the accessibility tree, but
/// the top wedge sits on the screen's vertical centre line, where an element
/// breaks XCUITest's app-level multi-touch tap
/// (docs/learnings/accessibility-element-blocks-app-multi-touch-tap.md), so
/// the rule is stated rather than inherited.
final class WeaponRingView: UIView {
    private let wedges: [WeaponWedgeView]
    /// Indexed by engine weapon number, as the sprites arrive.
    private let spriteImages = WeaponSpriteImages(count: WeaponSelectModel.names.count)

    override init(frame: CGRect) {
        wedges = (0..<WeaponRingGeometry.wedgeCount).map { WeaponWedgeView(index: $0) }
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        wedges.forEach(addSubview)
        exposeWedges()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isHidden: Bool {
        didSet { exposeWedges() }
    }

    private func exposeWedges() {
        for wedge in wedges { wedge.isAccessibilityElement = !isHidden }
    }

    /// Wedge subviews carry accessibilityIdentifier "weaponCell0"…"weaponCell6"
    /// (the grid's scheme, by slot), accessibilityLabel = the resolved
    /// weapon's name (the slot's first weapon when none is owned), value =
    /// "not owned" / "ready" / "out of ammo", the `.button` trait, and
    /// `.notEnabled` when the slot resolves to nothing. Each wedge view's frame
    /// is its sprite square, centred on the wedge's midpoint, so the centre of
    /// its accessibility frame (where XCUITest taps) is on the drawn wedge;
    /// the panel is drawn by a layer that reaches outside that frame, and is
    /// also the wedge's `accessibilityPath`, so VoiceOver outlines and
    /// explores the panel itself rather than the overlapping squares.
    /// `sprites` is nine entries in engine weapon order.
    func update(geometry: WeaponRingGeometry, model: WeaponRingModel,
                sprites: [DoomGraphics.Bitmap?]) {
        let side = geometry.spriteSide
        let gap = max(1, (geometry.outerRadius * 0.02).rounded())
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, wedge) in wedges.enumerated() {
            let resolved = model.resolvedWeapon(i)
            let shown = WeaponRingSlots.displayWeapon(i, slots: model.slots, selected: model.selectedWeapon)
            let appearance = model.appearance(i)
            let image = sprites.indices.contains(shown)
                ? spriteImages.image(for: sprites[shown], at: shown, silhouette: resolved == nil) : nil
            let mid = geometry.wedgeMidpoint(i)
            wedge.frame = CGRect(x: mid.x - side / 2, y: mid.y - side / 2, width: side, height: side)
            let angles = geometry.wedgeAngles(i)
            let center = CGPoint(x: geometry.center.x - wedge.frame.minX,
                                 y: geometry.center.y - wedge.frame.minY)
            wedge.configure(
                panel: Self.panelPath(center: center, inner: geometry.innerRadius, outer: geometry.outerRadius,
                                      start: angles.start, end: angles.end, gap: gap),
                spriteFloorY: center.y - gap,
                appearance: appearance,
                accented: model.selectedSlot == i,
                name: WeaponSelectModel.names[shown],
                state: resolved.map { model.slots[$0] },
                sprite: image,
                edgeWidth: max(1, (geometry.outerRadius * 0.012).rounded()))
        }
        CATransaction.commit()
    }

    /// An annular sector with `gap` points of clear between neighbours: each
    /// side is pulled in by the angle that half the gap subtends at that
    /// radius, so the gap is the same width along its length.
    static func panelPath(center: CGPoint, inner: CGFloat, outer: CGFloat,
                          start: CGFloat, end: CGFloat, gap: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard inner > 0, outer > inner else { return path }
        let outerInset = min(gap / 2 / outer, (end - start) / 2)
        let innerInset = min(gap / 2 / inner, (end - start) / 2)
        path.addArc(center: center, radius: outer, startAngle: start + outerInset,
                    endAngle: end - outerInset, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: end - innerInset,
                    endAngle: start + innerInset, clockwise: true)
        path.closeSubpath()
        return path
    }

    /// Aspect-fitted into `box`, centred, then moved up if needed so its
    /// bottom is no lower than `floorY`. Only the end wedges (0 and 6), whose
    /// midpoints sit 0.156 · R above the centre line, need the nudge: an
    /// unmoved square sprite there would reach 0.084 · R below the line,
    /// where there is no panel.
    static func spriteRect(imageSize: CGSize, box: CGRect, floorY: CGFloat) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(box.width / imageSize.width, box.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        var rect = CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                          width: size.width, height: size.height)
        if rect.maxY > floorY { rect.origin.y -= rect.maxY - floorY }
        return rect
    }

    func wedgeFrameForTesting(_ index: Int) -> CGRect { wedges[index].frame }
    /// The panel path in this view's coordinates.
    func panelPathForTesting(_ index: Int) -> CGPath? {
        guard let path = wedges[index].panelPath else { return nil }
        let origin = wedges[index].frame.origin
        var move = CGAffineTransform(translationX: origin.x, y: origin.y)
        return path.copy(using: &move)
    }
    /// The sprite's drawn rectangle in this view's coordinates, or nil.
    func spriteFrameForTesting(_ index: Int) -> CGRect? {
        guard let rect = wedges[index].spriteRect else { return nil }
        return rect.offsetBy(dx: wedges[index].frame.minX, dy: wedges[index].frame.minY)
    }
    func isAccentedForTesting(_ index: Int) -> Bool { wedges[index].isAccented }
    func hasSpriteForTesting(_ index: Int) -> Bool { wedges[index].hasSprite }
}

/// One wedge: the panel layer and the sprite. The sprite is aspect-fitted
/// into the view's square, nearest-neighbour, upright, and clipped to the
/// panel, so nothing of it draws outside the wedge.
private final class WeaponWedgeView: UIView {
    /// Brighter than `ready`, for the wedge a lift would pick. The grid's
    /// `pressed` is darker than its `ready`, which suits a cell under a
    /// finger but not a highlight the finger is sliding towards.
    private static let highlight = UIColor(red: 0.66, green: 0.59, blue: 0.46, alpha: 0.95)
    private static let accent = WeaponPanelPalette.text.cgColor

    private let panel = CAShapeLayer()
    /// Clips the sprite to the panel.
    private let spriteClip = CALayer()
    private let spriteMask = CAShapeLayer()
    private let spriteLayer = CALayer()
    private(set) var isAccented = false
    private(set) var panelPath: CGPath?
    var hasSprite: Bool { spriteLayer.contents != nil }
    var spriteRect: CGRect? { spriteLayer.isHidden ? nil : spriteLayer.frame }

    /// The panel, in screen coordinates, computed when asked so it follows
    /// layout, rotation and the window.
    override var accessibilityPath: UIBezierPath? {
        get {
            guard let panelPath else { return nil }
            return UIAccessibility.convertToScreenCoordinates(UIBezierPath(cgPath: panelPath), in: self)
        }
        set {}  // derived from the panel; not settable
    }

    init(index: Int) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        accessibilityIdentifier = "weaponCell\(index)"

        panel.lineJoin = .miter
        layer.addSublayer(panel)
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        spriteClip.mask = spriteMask
        spriteClip.addSublayer(spriteLayer)
        layer.addSublayer(spriteClip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(panel path: CGPath, spriteFloorY: CGFloat, appearance: WeaponCellAppearance, accented: Bool,
                   name: String, state: WeaponSlotState?, sprite: CGImage?, edgeWidth: CGFloat) {
        let fill: UIColor
        switch appearance {
        case .unowned: fill = WeaponPanelPalette.unowned
        case .ready: fill = WeaponPanelPalette.ready
        case .empty: fill = WeaponPanelPalette.empty
        case .pressed: fill = Self.highlight
        }
        panel.frame = bounds
        panel.path = path
        panelPath = path
        panel.fillColor = fill.cgColor
        isAccented = accented
        panel.strokeColor = accented ? Self.accent : WeaponPanelPalette.edge
        panel.lineWidth = accented ? edgeWidth * 2 : edgeWidth

        accessibilityLabel = name
        // Pressed is visual only: the value is the weapon underneath it.
        accessibilityValue = state.map { $0.canFire ? "ready" : "out of ammo" } ?? "not owned"
        accessibilityTraits = state != nil ? .button : [.button, .notEnabled]

        spriteClip.frame = bounds
        spriteMask.frame = bounds
        spriteMask.path = path
        spriteLayer.frame = sprite.map {
            WeaponRingView.spriteRect(imageSize: CGSize(width: $0.width, height: $0.height),
                                      box: bounds, floorY: spriteFloorY)
        } ?? bounds
        spriteLayer.contents = sprite
        spriteLayer.isHidden = sprite == nil
        spriteLayer.opacity = appearance == .unowned ? 0.6 : 1
    }
}
