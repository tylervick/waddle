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
    /// its accessibility frame is inside the wedge; the panel is drawn by a
    /// layer that reaches outside that frame. `sprites` is nine entries in
    /// engine weapon order.
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

    func wedgeFrameForTesting(_ index: Int) -> CGRect { wedges[index].frame }
    func isAccentedForTesting(_ index: Int) -> Bool { wedges[index].isAccented }
    func hasSpriteForTesting(_ index: Int) -> Bool { wedges[index].hasSprite }
}

/// One wedge: the panel layer and the sprite. The sprite fills the view's
/// square, aspect-fitted, nearest-neighbour, upright.
private final class WeaponWedgeView: UIView {
    /// Brighter than `ready`, for the wedge a lift would pick. The grid's
    /// `pressed` is darker than its `ready`, which suits a cell under a
    /// finger but not a highlight the finger is sliding towards.
    private static let highlight = UIColor(red: 0.66, green: 0.59, blue: 0.46, alpha: 0.95)
    private static let accent = WeaponPanelPalette.text.cgColor

    private let panel = CAShapeLayer()
    private let spriteLayer = CALayer()
    private(set) var isAccented = false
    var hasSprite: Bool { spriteLayer.contents != nil }

    init(index: Int) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        accessibilityIdentifier = "weaponCell\(index)"

        panel.lineJoin = .miter
        layer.addSublayer(panel)
        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resizeAspect
        layer.addSublayer(spriteLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(panel path: CGPath, appearance: WeaponCellAppearance, accented: Bool,
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
        panel.fillColor = fill.cgColor
        isAccented = accented
        panel.strokeColor = accented ? Self.accent : WeaponPanelPalette.edge
        panel.lineWidth = accented ? edgeWidth * 2 : edgeWidth

        accessibilityLabel = name
        // Pressed is visual only: the value is the weapon underneath it.
        accessibilityValue = state.map { $0.canFire ? "ready" : "out of ammo" } ?? "not owned"
        accessibilityTraits = state != nil ? .button : [.button, .notEnabled]

        spriteLayer.frame = bounds
        spriteLayer.contents = sprite
        spriteLayer.isHidden = sprite == nil
        spriteLayer.opacity = appearance == .unowned ? 0.6 : 1
    }
}
