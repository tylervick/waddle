import CoreGraphics

/// The weapon-select ring's drawing arithmetic: the wedge panel's outline
/// and where a sprite goes inside it. Pure CoreGraphics, so `WaddleTests`
/// pins it without UIKit; `WeaponRingView` draws with it.
enum WeaponRingDrawing {
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

    /// The sprite's rectangle in a wedge: the largest rectangle of the
    /// sprite's own aspect ratio, centred on the wedge's midpoint `center`
    /// (and nudged up to `floorY` as `spriteRect` does), whose edges lie
    /// inside `panel`. It starts from the aspect fit to the `side` square and
    /// shrinks by 5 % steps until every sampled edge point (the four corners
    /// and three more along each edge, since the inner arc is concave) is
    /// inside the panel. A panel is narrower than the square across the
    /// wedge (about 0.32 · R at the midpoint of wedge 3), so a wide sprite
    /// shrinks rather than being cut. The panel mask stays as a safety net.
    static func fittedSpriteRect(imageSize: CGSize, center: CGPoint, side: CGFloat,
                                 floorY: CGFloat, panel: CGPath) -> CGRect {
        var scale: CGFloat = 1
        var rect = CGRect.zero
        for _ in 0..<60 {
            let s = side * scale
            let box = CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s)
            rect = spriteRect(imageSize: imageSize, box: box, floorY: floorY)
            if rect.isEmpty || edgePoints(of: rect).allSatisfy({ panel.contains($0) }) { return rect }
            scale *= 0.95
        }
        return rect
    }

    /// The corners and three evenly spaced points along each edge.
    static func edgePoints(of rect: CGRect) -> [CGPoint] {
        let xs = (0...4).map { rect.minX + rect.width * CGFloat($0) / 4 }
        let ys = (0...4).map { rect.minY + rect.height * CGFloat($0) / 4 }
        return xs.flatMap { [CGPoint(x: $0, y: rect.minY), CGPoint(x: $0, y: rect.maxY)] }
            + ys.dropFirst().dropLast().flatMap { [CGPoint(x: rect.minX, y: $0), CGPoint(x: rect.maxX, y: $0)] }
    }

}
