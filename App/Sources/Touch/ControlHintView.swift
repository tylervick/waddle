import UIKit

/// The overlay's control hints (issue #392): a translucent shape over the
/// weapon zone labelled "Weapons" and, in the Modern scheme, "Move" and
/// "Aim" circles over the stick side and the drag-turn side. In the
/// overlay's own style, the translucent white of the buttons and the stick.
///
/// Drawing only. It takes no touches, and neither it nor anything in it is
/// ever an accessibility element: the Weapons hint sits on the screen's
/// vertical centre line, where an element breaks XCUITest's app-level
/// multi-touch tap
/// (docs/learnings/accessibility-element-blocks-app-multi-touch-tap.md).
/// VoiceOver finds the zone through the `weaponSelectHotspot` view instead.
///
/// `ControlHintModel` says when it shows and `ControlHintGeometry` where;
/// the geometry is in this view's coordinates, so the overlay lays this
/// view out to fill itself.
final class ControlHintView: UIView {
    static let weaponsTitle = "Weapons"
    static let moveTitle = "Move"
    static let aimTitle = "Aim"
    /// A fade in, so the hint does not pop up in front of the player. Hiding
    /// is immediate: the finger that came down wants the screen now.
    static let fadeInDuration: TimeInterval = 0.4

    private let weapons = HintShapeView(title: weaponsTitle)
    private let move = HintShapeView(title: moveTitle)
    private let aim = HintShapeView(title: aimTitle)
    private(set) var hints = ControlHintModel.Hints.hidden

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
        alpha = 0
        for shape in [weapons, move, aim] { addSubview(shape) }
        move.isHidden = true
        aim.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(geometry: ControlHintGeometry) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        weapons.frame = geometry.weaponsFrame
        switch geometry.weaponsShape {
        case .disc(let center, let radius):
            let local = CGPoint(x: center.x - geometry.weaponsFrame.minX,
                                y: center.y - geometry.weaponsFrame.minY)
            weapons.setShape(UIBezierPath(arcCenter: local, radius: radius, startAngle: 0,
                                          endAngle: .pi * 2, clockwise: true).cgPath)
        case .rectangle:
            weapons.setShape(UIBezierPath(rect: weapons.bounds).cgPath)
        }
        for (shape, frame) in [(move, geometry.moveFrame), (aim, geometry.aimFrame)] {
            shape.frame = frame
            shape.setShape(UIBezierPath(ovalIn: shape.bounds).cgPath)
        }
        CATransaction.commit()
    }

    /// Shows what the model says. Appearing fades in; everything else,
    /// hiding included, is immediate.
    func show(_ new: ControlHintModel.Hints) {
        guard new != hints else { return }
        let appearing = new.weapons && !hints.weapons
        hints = new
        move.isHidden = !new.moveAndAim
        aim.isHidden = !new.moveAndAim
        layer.removeAllAnimations()
        if appearing {
            UIView.animate(withDuration: Self.fadeInDuration, delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction]) { self.alpha = 1 }
        } else {
            alpha = new.weapons ? 1 : 0
        }
    }

    var weaponsFrameForTesting: CGRect { weapons.frame }
    var moveFrameForTesting: CGRect? { move.isHidden ? nil : move.frame }
    var aimFrameForTesting: CGRect? { aim.isHidden ? nil : aim.frame }
}

/// One hint: a filled, outlined shape and its name. The shape is clipped to
/// the view's bounds, which is how the ring's disc ends where the picture
/// does.
private final class HintShapeView: UIView {
    private let shape = CAShapeLayer()
    private let label = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        clipsToBounds = true

        // The stick base's fill and stroke.
        shape.fillColor = UIColor.white.withAlphaComponent(0.12).cgColor
        shape.strokeColor = UIColor.white.withAlphaComponent(0.35).cgColor
        shape.lineWidth = 2
        layer.addSublayer(shape)

        // An overlay button's lettering. A UILabel is an accessibility
        // element unless told otherwise.
        label.text = title
        label.textColor = UIColor.white.withAlphaComponent(0.7)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        label.baselineAdjustment = .alignCenters
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setShape(_ path: CGPath) {
        shape.frame = bounds
        shape.path = path
        // Inset so the lettering clears the outline of a round shape.
        label.frame = bounds.insetBy(dx: bounds.width * 0.1, dy: 0)
        label.font = .systemFont(ofSize: max(11, min(bounds.width, bounds.height) * 0.2), weight: .bold)
    }
}
