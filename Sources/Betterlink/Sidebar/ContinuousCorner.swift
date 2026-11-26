import AppKit

/// The corner macOS draws on windows, as an outline: for each step down from
/// the edge, how far in the corner's curve starts. AppKit has no public API
/// for that shape. `window` and `largest` read it from the mask AppKit keeps
/// for a window of that style (`_cornerMask`: the image the window is shaped
/// with), so they are the system's own on whatever macOS this runs.
/// `init(radius:)` draws the same continuous ("squircle") curve with a
/// CALayer, for when the mask can't be read. Both are drawn at 8x and measured.
struct ContinuousCorner {
    /// (distance from the edge, how far the curve is set in at that distance), in points.
    let profile: [(CGFloat, CGFloat)]
    /// How far along the edge the corner differs from a square one.
    let span: CGFloat

    /// A browser window's style: titled, its content under the title bar, no
    /// toolbar (what Chromium browsers open).
    static let browserStyle: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
    /// The corner of such a window on this macOS. Should that not be
    /// readable: the 16 pt curve macOS 26.5 gives it.
    @MainActor static let window = ContinuousCorner(windowStyle: browserStyle, toolbar: false) ?? ContinuousCorner(radius: 16)
    /// The largest corner macOS gives a window: one with a toolbar. Should
    /// that not be readable: macOS 26.5's, 26 pt.
    @MainActor static let largest = ContinuousCorner(windowStyle: browserStyle, toolbar: true) ?? ContinuousCorner(radius: 26)

    private static let scale: CGFloat = 8

    private init(profile: [(CGFloat, CGFloat)], span: CGFloat) {
        self.profile = profile
        self.span = span
    }

    /// One corner of a filled shape `n` pixels square at 8x, from its alpha.
    private init(side n: Int, alpha: (_ row: Int, _ x: Int) -> CGFloat) {
        var out: [(CGFloat, CGFloat)] = []
        var span = 0
        for row in 0..<(n / 2) {
            // The transparent run at the start of this row: how much of it
            // is clear, and how long it is.
            var clear: CGFloat = 0, run = 0
            for x in 0..<(n / 2) {
                let a = alpha(row, x)
                if a >= 0.999 { break }
                clear += 1 - a
                run = x + 1
            }
            span = max(span, run)
            out.append((CGFloat(row) / Self.scale, clear / Self.scale))
            if clear == 0 { break }
        }
        self.init(profile: out, span: CGFloat(span) / Self.scale)
    }

    /// The continuous curve of a layer with corner radius `r`.
    init(radius r: CGFloat) {
        // Four radii a side: the curve runs about one and a half along each edge.
        let n = Int(r * 4 * Self.scale)
        guard r > 0, let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data else { self.init(profile: [], span: 0); return }
        ctx.scaleBy(x: Self.scale, y: Self.scale)
        let l = CALayer()
        l.frame = CGRect(x: 0, y: 0, width: r * 4, height: r * 4)
        l.backgroundColor = CGColor(gray: 0, alpha: 1)
        l.cornerRadius = r
        l.cornerCurve = .continuous
        l.render(in: ctx)
        let a = data.assumingMemoryBound(to: UInt8.self)
        self.init(side: n) { row, x in CGFloat(a[row * n + x]) / 255 }
    }

    /// The corner macOS gives a window of `style`, with a toolbar or without,
    /// on this version: read from the mask of one that is never shown. Nil
    /// when AppKit no longer hands the mask out, or it is no rounded shape.
    @MainActor init?(windowStyle style: NSWindow.StyleMask, toolbar: Bool) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: style, backing: .buffered, defer: true)
        if toolbar {
            w.toolbar = NSToolbar()
            w.toolbarStyle = .unified
        }
        let sel = NSSelectorFromString("_cornerMask")
        guard w.responds(to: sel), let mask = w.perform(sel)?.takeUnretainedValue() as? NSImage else { return nil }
        let side = mask.size.width, n = Int(side * Self.scale)
        guard side == mask.size.height, side >= 2, side <= 256,
              let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return nil }
        ctx.scaleBy(x: Self.scale, y: Self.scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        mask.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let a = data.assumingMemoryBound(to: UInt8.self)
        let alpha = { (row: Int, x: Int) in CGFloat(a[(row * n + x) * 4 + 3]) / 255 }
        let read = ContinuousCorner(side: n, alpha: alpha)
        // A corner: clear at the very corner, filled in the middle, and the
        // curve over before the middle.
        guard read.span > 0, read.profile.last?.1 == 0, alpha(n / 2, n / 2) >= 0.999 else { return nil }
        self = read
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
