import UIKit

/// The weapon selectors' panel colours, shared by the grid and the ring.
/// Picked from the range of Doom's own palette (its greys, browns and blood
/// reds) rather than the app shell's theme, which belongs to the library,
/// not the game.
enum WeaponPanelPalette {
    static let unowned = UIColor(red: 0.16, green: 0.16, blue: 0.16, alpha: 0.9)
    static let ready = UIColor(red: 0.43, green: 0.39, blue: 0.33, alpha: 0.9)
    static let empty = UIColor(red: 0.52, green: 0.06, blue: 0.06, alpha: 0.9)
    static let pressed = UIColor(red: 0.30, green: 0.30, blue: 0.30, alpha: 0.9)
    static let edge = UIColor(white: 0, alpha: 0.75).cgColor
    static let text = UIColor(red: 0.96, green: 0.91, blue: 0.78, alpha: 1)
}

/// Weapon sprites converted to `CGImage`s, keyed by the bitmaps they came
/// from, so a view's `update` (called on every poll) only converts a sprite
/// when it changes. Indexed by engine weapon number.
final class WeaponSpriteImages {
    private var sources: [DoomGraphics.Bitmap?]
    private var images: [CGImage?]
    private var silhouettes: [CGImage?]

    init(count: Int) {
        sources = Array(repeating: nil, count: count)
        images = Array(repeating: nil, count: count)
        silhouettes = Array(repeating: nil, count: count)
    }

    /// The image for `bitmap` at `index`, or its silhouette (same alpha, no
    /// colour) for a weapon not owned. nil for no bitmap, one that does not
    /// convert, or an index outside the cache.
    func image(for bitmap: DoomGraphics.Bitmap?, at index: Int, silhouette: Bool) -> CGImage? {
        guard sources.indices.contains(index) else { return nil }
        if bitmap != sources[index] {
            sources[index] = bitmap
            images[index] = bitmap.flatMap(Self.makeImage)
            silhouettes[index] = nil
        }
        guard let bitmap else { return nil }
        if silhouette {
            if silhouettes[index] == nil { silhouettes[index] = Self.makeImage(bitmap.silhouette()) }
            return silhouettes[index]
        }
        return images[index]
    }

    /// RGBA, straight alpha, row-major, as `DoomGraphics` produces it.
    static func makeImage(_ bitmap: DoomGraphics.Bitmap) -> CGImage? {
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
