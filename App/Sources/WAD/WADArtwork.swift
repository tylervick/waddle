import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Orchestrates TITLEPIC (+ PLAYPAL) lookup across candidate WADs into a
/// `CGImage`, disk-caching the PNG-encoded result by a caller-supplied key so
/// repeat lookups (e.g. library thumbnails) skip the decode entirely.
enum WADArtwork {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TitleArt", isDirectory: true)
    }

    private static func cacheURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).png")
    }

    /// Removes the cached PNG for `key`, if any. Used by tests for hygiene
    /// and available for callers that need to invalidate a stale entry.
    static func clearCache(key: String) {
        try? FileManager.default.removeItem(at: cacheURL(forKey: key))
    }

    /// Finds TITLEPIC in the first candidate that has it (and PLAYPAL in the
    /// first that has it, which may be a different candidate), decodes it —
    /// PNG lump via ImageIO, else the DOOM picture format via `DoomGraphics`
    /// — and returns a `CGImage`, disk-caching the PNG encoding by
    /// `cacheKey`. Never runs decode work on the caller's actor. Returns
    /// `nil` if no candidate has TITLEPIC or it can't be decoded.
    static func titleImage(candidates: [URL], cacheKey: String) async -> CGImage? {
        await Task.detached(priority: .utility) {
            let cacheURL = cacheURL(forKey: cacheKey)

            // 1. Cache hit.
            if FileManager.default.fileExists(atPath: cacheURL.path),
               let source = CGImageSourceCreateWithURL(cacheURL as CFURL, nil),
               let cached = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                return cached
            }

            // 2. Find lumps: first candidate with TITLEPIC, first with PLAYPAL.
            var titlepicURL: URL?
            var titlepicIndex: WADLumpIndex?
            var palettepicURL: URL?
            var paletteIndex: WADLumpIndex?
            for url in candidates {
                guard let index = try? WADLumpIndex.read(from: url) else { continue }
                if titlepicIndex == nil, index.offsetSize(of: "TITLEPIC") != nil {
                    titlepicURL = url
                    titlepicIndex = index
                }
                if paletteIndex == nil, index.offsetSize(of: "PLAYPAL") != nil {
                    palettepicURL = url
                    paletteIndex = index
                }
            }
            guard let titlepicURL, let titlepicIndex else { return nil }

            // 3. Read TITLEPIC bytes.
            guard let bytes = try? WADLumpIndex.lumpData("TITLEPIC", at: titlepicURL, index: titlepicIndex) else {
                return nil
            }

            let image: CGImage?
            if bytes.count >= pngSignature.count, Array(bytes.prefix(pngSignature.count)) == pngSignature {
                // 4. PNG branch.
                image = (CGImageSourceCreateWithData(bytes as CFData, nil)).flatMap {
                    CGImageSourceCreateImageAtIndex($0, 0, nil)
                }
            } else {
                // 5. Picture branch.
                var palette: [UInt8]?
                if let palettepicURL, let paletteIndex,
                   let playpal = try? WADLumpIndex.lumpData("PLAYPAL", at: palettepicURL, index: paletteIndex) {
                    palette = DoomGraphics.palette(from: playpal)
                }
                let resolvedPalette = palette ?? [UInt8](repeating: 0, count: 256 * 4)
                guard let bitmap = DoomGraphics.decodePicture(bytes, palette: resolvedPalette) else {
                    return nil
                }
                image = Self.cgImage(from: bitmap)
            }
            guard let image else { return nil }

            // 6. Write cache (non-fatal on failure).
            try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            if let destination = CGImageDestinationCreateWithURL(cacheURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }

            return image
        }.value
    }

    private static func cgImage(from bitmap: DoomGraphics.Bitmap) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bitmap.rgba) as CFData) else { return nil }
        return CGImage(
            width: bitmap.width,
            height: bitmap.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bitmap.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
