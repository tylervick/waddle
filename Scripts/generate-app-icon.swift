#!/usr/bin/env swift
// Generates the BoomBox app icon: a deterministic 1024x1024 PNG with a dark
// charcoal field, a subtle vignette, and a centered upward flame mark built
// from three overlapping teardrop beziers in a Doom-orange gradient
// (#FF6A00 -> #FFC933). No text. Run from the repo root:
//
//   swift Scripts/generate-app-icon.swift
//
// Writes App/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png plus both
// Contents.json files, so the whole asset catalog is reproducible from this
// one command. The canvas is full-bleed (no transparency, no pre-rounded
// corners): iOS applies the superellipse mask itself, and App Store 1024px
// marketing icons must be square and opaque.

import CoreGraphics
import Foundation
import ImageIO

let side = 1024
let s = CGFloat(side)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ stops: [(CGColor, CGFloat)]) -> CGGradient {
    CGGradient(
        colorsSpace: colorSpace,
        colors: stops.map(\.0) as CFArray,
        locations: stops.map(\.1)
    )!
}

// Teardrop flame: round bottom, sides that bulge out then taper concavely
// into an upward tip. CG coordinates (origin bottom-left, y up).
func teardrop(cx: CGFloat, baseY: CGFloat, width w: CGFloat, height h: CGFloat) -> CGPath {
    let tip = CGPoint(x: cx, y: baseY + h)
    let bottom = CGPoint(x: cx, y: baseY)
    let right = CGPoint(x: cx + w / 2, y: baseY + h * 0.30)
    let left = CGPoint(x: cx - w / 2, y: baseY + h * 0.30)
    let p = CGMutablePath()
    p.move(to: tip)
    p.addCurve(
        to: right,
        control1: CGPoint(x: cx + w * 0.06, y: baseY + h * 0.72),
        control2: CGPoint(x: cx + w * 0.50, y: baseY + h * 0.58)
    )
    p.addCurve(
        to: bottom,
        control1: CGPoint(x: cx + w * 0.50, y: baseY + h * 0.10),
        control2: CGPoint(x: cx + w * 0.32, y: baseY)
    )
    p.addCurve(
        to: left,
        control1: CGPoint(x: cx - w * 0.32, y: baseY),
        control2: CGPoint(x: cx - w * 0.50, y: baseY + h * 0.10)
    )
    p.addCurve(
        to: tip,
        control1: CGPoint(x: cx - w * 0.50, y: baseY + h * 0.58),
        control2: CGPoint(x: cx - w * 0.06, y: baseY + h * 0.72)
    )
    p.closeSubpath()
    return p
}

func fill(_ ctx: CGContext, flame: CGPath, from base: CGColor, to tipColor: CGColor) {
    let box = flame.boundingBox
    ctx.saveGState()
    ctx.addPath(flame)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([(base, 0.0), (tipColor, 1.0)]),
        start: CGPoint(x: box.midX, y: box.minY),
        end: CGPoint(x: box.midX, y: box.maxY),
        options: []
    )
    ctx.restoreGState()
}

let ctx = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
)!

// Charcoal field: barely-lighter top so the flat dark doesn't read as a hole.
ctx.drawLinearGradient(
    gradient([(rgb(0x26262B), 0.0), (rgb(0x18181B), 1.0)]),
    start: CGPoint(x: s / 2, y: s),
    end: CGPoint(x: s / 2, y: 0),
    options: []
)

// Warm ember glow behind the mark so the flame sits in light, not on black.
ctx.drawRadialGradient(
    gradient([(rgb(0xFF6A00, 0.30), 0.0), (rgb(0xFF6A00, 0.10), 0.55), (rgb(0xFF6A00, 0.0), 1.0)]),
    startCenter: CGPoint(x: s / 2, y: 460),
    startRadius: 0,
    endCenter: CGPoint(x: s / 2, y: 460),
    endRadius: 430,
    options: []
)

// Flanking flames behind, in deeper embers; the central flame overlaps both.
fill(ctx, flame: teardrop(cx: 388, baseY: 268, width: 300, height: 400), from: rgb(0xC93E00), to: rgb(0xFF8A1E))
fill(ctx, flame: teardrop(cx: 646, baseY: 268, width: 270, height: 356), from: rgb(0xC93E00), to: rgb(0xFF8A1E))
fill(ctx, flame: teardrop(cx: 512, baseY: 252, width: 430, height: 560), from: rgb(0xFF6A00), to: rgb(0xFFC933))

// Subtle vignette: clear across the middle, gently darker toward corners.
ctx.drawRadialGradient(
    gradient([(rgb(0x000000, 0.0), 0.0), (rgb(0x000000, 0.0), 0.55), (rgb(0x000000, 0.32), 1.0)]),
    startCenter: CGPoint(x: s / 2, y: s / 2),
    startRadius: 0,
    endCenter: CGPoint(x: s / 2, y: s / 2),
    endRadius: s * 0.74,
    options: []
)

let image = ctx.makeImage()!

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let catalog = repoRoot.appendingPathComponent("App/Assets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

let pngURL = iconSet.appendingPathComponent("AppIcon-1024.png")
let dest = CGImageDestinationCreateWithURL(pngURL as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else {
    fatalError("failed to write \(pngURL.path)")
}

try #"""
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""#.write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

try #"""
{
  "images" : [
    {
      "filename" : "AppIcon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""#.write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)

print("wrote \(pngURL.path)")
