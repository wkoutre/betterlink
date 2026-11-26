import AppKit

/// The continuous ("squircle") corner macOS draws on windows, as an outline.
/// AppKit has no API for that path, so it is read once from a CALayer with
/// `cornerCurve = .continuous`, rendered at 8x: for each step down from the
/// edge, how far in the corner's curve starts.
struct ContinuousCorner {
    /// (distance from the edge, how far the curve is set in at that distance), in points.
    let profile: [(CGFloat, CGFloat)]
    /// How far along each edge the curve reaches.
    var extent: CGFloat { profile.first?.1 ?? 0 }

    init(radius r: CGFloat) {
        let scale: CGFloat = 8, size = Int(r * 3 * scale)
        guard r > 0, let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data else { profile = []; return }
        ctx.scaleBy(x: scale, y: scale)
        let l = CALayer()
        l.frame = CGRect(x: 0, y: 0, width: r * 3, height: r * 3)
        l.backgroundColor = CGColor(gray: 0, alpha: 1)
        l.cornerRadius = r
        l.cornerCurve = .continuous
        l.render(in: ctx)
        let a = data.assumingMemoryBound(to: UInt8.self)
        var out: [(CGFloat, CGFloat)] = []
        for row in 0..<(size / 2) {
            // Coverage of the transparent run at the start of this row, in pixels.
            var clear: CGFloat = 0
            for x in 0..<(size / 2) {
                let alpha = CGFloat(a[row * size + x]) / 255
                if alpha >= 0.999 { break }
                clear += 1 - alpha
            }
            out.append((CGFloat(row) / scale, clear / scale))
            if clear == 0 { break }
        }
        profile = out
    }

    /// The outline of the bit of a `w`-wide strip, standing on the edge of a
    /// window whose corner this is, that the corner leaves uncovered. Panel
    /// coordinates: the window's edge at `edgeX`, the window to the left when
    /// `windowLeft`, the corner at the top (`top` true) or bottom.
    func notch(edgeX: CGFloat, windowLeft: Bool, top: Bool, height h: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let y = { (d: CGFloat) in top ? h - d : d }
        let x = { (inset: CGFloat) in windowLeft ? edgeX - inset : edgeX + inset }
        p.move(to: CGPoint(x: edgeX, y: y(0)))
        for (d, inset) in profile { p.addLine(to: CGPoint(x: x(inset), y: y(d))) }
        p.addLine(to: CGPoint(x: edgeX, y: y(profile.last?.0 ?? 0)))
        p.closeSubpath()
        return p
    }

    /// A rect whose chosen corners follow this curve; the others stay square.
    /// Corners: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left (y up).
    func rect(_ r: CGRect, corners: Set<Int>) -> CGPath {
        var path = CGPath(rect: r, transform: nil)
        let all: [(Int, CGPoint, CGFloat, CGFloat)] = [(0, CGPoint(x: r.minX, y: r.maxY), 1, -1), (1, CGPoint(x: r.maxX, y: r.maxY), -1, -1),
                                                       (2, CGPoint(x: r.maxX, y: r.minY), -1, 1), (3, CGPoint(x: r.minX, y: r.minY), 1, 1)]
        for (i, o, sx, sy) in all where corners.contains(i) {
            // The sliver between the rect's corner point and the curve.
            let cut = CGMutablePath()
            cut.move(to: o)
            for (d, inset) in profile { cut.addLine(to: CGPoint(x: o.x + sx * inset, y: o.y + sy * d)) }
            cut.addLine(to: CGPoint(x: o.x, y: o.y + sy * (profile.last?.0 ?? 0)))
            cut.closeSubpath()
            path = path.subtracting(cut)
        }
        return path
    }
}
