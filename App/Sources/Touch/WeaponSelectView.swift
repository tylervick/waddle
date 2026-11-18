import UIKit

/// The weapon-select grid's drawing: nine cells over the game picture, each a
/// flat panel in the game's dark palette with the weapon's name near the top
/// and its sprite pinned bottom-centre. Square corners, opaque-ish fills and
/// nearest-neighbour pixels so it reads as part of the game, not iOS chrome:
/// no blur, no system materials.
///
/// Drawing only. `isUserInteractionEnabled` is false on the view and every
/// cell, so touches fall through to the overlay, which owns them and drives
/// `WeaponSelectModel`. Geometry frames are in this view's coordinate space,
/// so the overlay lays this view out to fill itself.
final class WeaponSelectView: UIView {
    private let cells: [WeaponCellView]

    /// Converted images, keyed by the bitmaps they came from, so `update`
    /// (called on every poll) only converts a sprite when it changes.
    private var spriteSources: [DoomGraphics.Bitmap?]
    private var spriteImages: [CGImage?]
    private var silhouetteImages: [CGImage?]

    override init(frame: CGRect) {
        let count = WeaponSelectGeometry.cellCount
        cells = (0..<count).map { WeaponCellView(name: WeaponSelectModel.names[$0], index: $0) }
        spriteSources = Array(repeating: nil, count: count)
        spriteImages = Array(repeating: nil, count: count)
        silhouetteImages = Array(repeating: nil, count: count)
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        cells.forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Cell subviews carry accessibilityIdentifier "weaponCell0"…"weaponCell8",
    /// accessibilityLabel = name, value = "not owned" / "ready" / "out of ammo".
    /// isUserInteractionEnabled is false on the view and its cells: the overlay
    /// owns the touches.
    func update(geometry: WeaponSelectGeometry, model: WeaponSelectModel,
                sprites: [DoomGraphics.Bitmap?]) {
        // Sprites are drawn at 1.25x native size in the predecessor's 480-wide
        // virtual screen, scaled with the picture, so a sprite keeps its old
        // proportion to its cell.
        let pixelScale = 1.25 * geometry.pictureRect.width / 480

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, cell) in cells.enumerated() {
            let appearance = model.appearance(i)
            let slot = model.slots.indices.contains(i)
                ? model.slots[i] : WeaponSlotState(owned: false, canFire: false)
            let image = sprites.indices.contains(i) ? image(for: sprites[i], at: i,
                                                            silhouette: appearance == .unowned) : nil
            cell.frame = geometry.cellFrame(i)
            cell.configure(appearance: appearance, slot: slot, sprite: image, pixelScale: pixelScale)
        }
        CATransaction.commit()
    }

    func cellFrameForTesting(_ index: Int) -> CGRect {
        cells[index].frame
    }

    private func image(for bitmap: DoomGraphics.Bitmap?, at i: Int, silhouette: Bool) -> CGImage? {
        if bitmap != spriteSources[i] {
            spriteSources[i] = bitmap
            spriteImages[i] = bitmap.flatMap(Self.makeImage)
            silhouetteImages[i] = nil
        }
        guard let bitmap else { return nil }
        if silhouette {
            if silhouetteImages[i] == nil { silhouetteImages[i] = Self.makeImage(bitmap.silhouette()) }
            return silhouetteImages[i]
        }
        return spriteImages[i]
    }

    /// RGBA, straight alpha, row-major, as `DoomGraphics` produces it.
    private static func makeImage(_ bitmap: DoomGraphics.Bitmap) -> CGImage? {
        guard bitmap.width > 0, bitmap.height > 0,
              bitmap.rgba.count == bitmap.width * bitmap.height * 4,
              let provider = CGDataProvider(data: Data(bitmap.rgba) as CFData) else { return nil }
        return CGImage(width: bitmap.width, height: bitmap.height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}

/// One cell: panel, name, sprite. Colours are picked from the range of
/// Doom's own palette (its greys, browns and blood reds) rather than the
/// app shell's theme, which belongs to the library, not the game.
private final class WeaponCellView: UIView {
    private enum Palette {
        static let unowned = UIColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 0.9)
        static let ready = UIColor(red: 0.43, green: 0.39, blue: 0.33, alpha: 0.9)
        static let empty = UIColor(red: 0.52, green: 0.06, blue: 0.06, alpha: 0.9)
        static let pressed = UIColor(red: 0.30, green: 0.30, blue: 0.30, alpha: 0.9)
        static let edge = UIColor(white: 0, alpha: 0.75).cgColor
        static let text = UIColor(red: 0.96, green: 0.91, blue: 0.78, alpha: 1)
    }

    private let nameLabel = UILabel()
    private let spriteLayer = CALayer()
    private var spritePixelSize = CGSize.zero
    private var pixelScale: CGFloat = 1

    init(name: String, index: Int) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.borderColor = Palette.edge

        isAccessibilityElement = true
        accessibilityIdentifier = "weaponCell\(index)"
        accessibilityLabel = name

        spriteLayer.magnificationFilter = .nearest
        spriteLayer.minificationFilter = .nearest
        spriteLayer.contentsGravity = .resize
        layer.addSublayer(spriteLayer)

        nameLabel.text = name.uppercased()
        nameLabel.textColor = Palette.text
        nameLabel.textAlignment = .center
        nameLabel.adjustsFontSizeToFitWidth = true
        nameLabel.minimumScaleFactor = 0.5
        // A hard, unblurred drop shadow, like the game's own HUD text.
        nameLabel.shadowColor = .black
        nameLabel.isUserInteractionEnabled = false
        addSubview(nameLabel)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func configure(appearance: WeaponCellAppearance, slot: WeaponSlotState,
                   sprite: CGImage?, pixelScale: CGFloat) {
        switch appearance {
        case .unowned: backgroundColor = Palette.unowned
        case .ready: backgroundColor = Palette.ready
        case .empty: backgroundColor = Palette.empty
        case .pressed: backgroundColor = Palette.pressed
        }
        nameLabel.alpha = (appearance == .unowned || appearance == .empty) ? 0.5 : 1

        // Pressed is visual only: the value is the slot underneath it.
        accessibilityValue = !slot.owned ? "not owned" : (slot.canFire ? "ready" : "out of ammo")

        spriteLayer.contents = sprite
        spriteLayer.isHidden = sprite == nil
        spritePixelSize = sprite.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        self.pixelScale = pixelScale
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height
        layer.borderWidth = max(1, (pixelScale * 1.6).rounded())

        nameLabel.font = .systemFont(ofSize: max(8, h * 0.17), weight: .black)
        nameLabel.shadowOffset = CGSize(width: max(1, pixelScale.rounded()), height: max(1, pixelScale.rounded()))
        nameLabel.frame = CGRect(x: bounds.minX + 4, y: bounds.minY + h * 0.05,
                                 width: bounds.width - 8, height: h * 0.25)

        // Bottom-centre pinned at 1.25x native size scaled with the picture;
        // anything taller or wider than the cell is clipped by the cell.
        let w = spritePixelSize.width * pixelScale
        let sh = spritePixelSize.height * pixelScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)   // a bare sublayer would animate its frame
        spriteLayer.frame = CGRect(x: bounds.midX - w / 2, y: bounds.maxY - sh, width: w, height: sh)
        CATransaction.commit()
    }
}
