// Rewrites a PNG without its alpha channel, optionally turned by quarter
// turns, for Scripts/capture-screenshots.sh's inner-display leg (issue #409).
//
//   xcrun swift Scripts/opaque-png.swift <in.png> <out.png> [0|90|180|270]
//
// Why this exists: `simctl io screenshot` writes RGBA whatever `--mask` and
// `--type` say, and the store refuses a screenshot with an alpha channel.
// `sips` cannot drop one from a PNG (it can only go through JPEG, which is
// lossy), and its `--rotate` leaves an EXIF and an XMP orientation behind
// that some readers then apply a second time (docs/app-store/metadata.md
// §12). Drawing into an opaque bitmap does both jobs and states no
// orientation. ImageIO still writes an eXIf chunk (colour space and pixel
// size only); the caller drops it, because the upload script refuses any.
//
// A picture with any pixel that is not fully opaque is refused, not blended.
//
// The turn is clockwise, as seen by someone looking at the picture. Pixels
// are copied one for one: the context has the source's own colour space and
// no interpolation, and a quarter turn maps the pixel grid onto itself.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("opaque-png: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else { fail("usage: opaque-png.swift <in.png> <out.png> [0|90|180|270]") }
let turn = args.count == 4 ? Int(args[3]) ?? -1 : 0
guard [0, 90, 180, 270].contains(turn) else { fail("the turn must be 0, 90, 180 or 270, got \(args[3])") }

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(args[1])") }
guard image.bitsPerComponent == 8 else { fail("\(args[1]) is \(image.bitsPerComponent) bits per component, expected 8") }

let (w, h) = (image.width, image.height)

// Refuse anything that is not fully opaque already. Dropping an alpha channel
// is lossless only when every pixel's alpha is 255; drawing a translucent
// picture onto black would change its colours and still exit 0 with a valid
// opaque PNG. A host shot taken with `--mask=ignored` is opaque throughout,
// so a translucent one means the capture changed, and that should stop here.
switch image.alphaInfo {
case .none, .noneSkipFirst, .noneSkipLast:
    break
default:
    // Premultiplying leaves the alpha byte itself as the file has it.
    guard let probe = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let bytes = probe.data?.bindMemory(to: UInt8.self, capacity: w * h * 4)
    else { fail("cannot inspect the alpha channel of \(args[1])") }
    probe.setBlendMode(.copy)
    probe.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var translucent = 0
    for i in stride(from: 3, to: w * h * 4, by: 4) where bytes[i] != 255 { translucent += 1 }
    guard translucent == 0 else {
        fail("\(args[1]) has \(translucent) pixel(s) that are not fully opaque; refusing to blend them onto black")
    }
}
let (outW, outH) = turn == 90 || turn == 270 ? (h, w) : (w, h)
let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fail("cannot make a \(outW)x\(outH) opaque bitmap") }
context.interpolationQuality = .none
context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
// CoreGraphics turns counter-clockwise for a positive angle, about the
// origin; turn about the centre of the output and draw the source centred.
context.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
context.rotate(by: -CGFloat(turn) * .pi / 180)
context.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))

guard let result = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil)
else { fail("cannot write \(args[2])") }
CGImageDestinationAddImage(destination, result, nil)
guard CGImageDestinationFinalize(destination) else { fail("cannot write \(args[2])") }
