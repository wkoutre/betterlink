import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where a sidebar panel meets its browser window. The panel lies directly
/// above the window and reaches over the window's edge as far as the
/// window's rounded corners go. There it is drawn only in the two notches
/// the corners leave open; the rest of that strip is clear, so a click there
/// is the window's. Its two outer corners are the window's own corner, so
/// the pair's four corners match. Pure math over Cocoa frames and screen
/// pixels, so it is unit tested.
public enum SidebarSeam {
    /// `v` on the nearest pixel of a screen with `scale` pixels per point.
    public static func aligned(_ v: CGFloat, scale: CGFloat) -> CGFloat {
        scale > 0 ? (v * scale).rounded() / scale : v
    }

    // MARK: - The window's corner radius

    /// The macOS major versions on which the window server was seen to tell
    /// a window's corner radius truly (26.5.2, against captures). On any
    /// other the fallback is used until it has been checked there.
    public static let verifiedSystems: Set<Int> = [26]

    /// The radii a window's corner can have. macOS 26 uses 16, 20 and 26.
    public static let saneRadii: ClosedRange<CGFloat> = 4...40

    /// The radius used when the window server can't be asked or gives no
    /// sane answer: what it reports for Chrome and Brave windows on macOS
    /// 26.5.2.
    public static let fallbackRadius: CGFloat = 20

    /// What the window server reported, when that is a radius a window can have.
    public static func radius(reported: CGFloat?) -> CGFloat? {
        guard let r = reported, r.isFinite, saneRadii.contains(r) else { return nil }
        return r
    }

    /// The radius to cut for after asking the window server: what it gave
    /// (`read`, nil when nothing usable). A read that gives nothing keeps
    /// the last radius that was read for this window: it says nothing about
    /// the window (the moment a window leaves full screen the window server
    /// may not have its corner back yet), and a corner cut for 20 pt beside
    /// a 16 pt window would stay until something asked again. The fallback
    /// is for a window never read.
    public static func radius(read: CGFloat?, lastRead: CGFloat?) -> CGFloat { read ?? lastRead ?? fallbackRadius }

    // MARK: - The panel's frame

    /// How many device pixels the seam's notch is cut into the window, on
    /// both axes (`CornerPixels.notch` says why one).
    public static let notchInset = 1

    /// How far the panel reaches over a window with corner radius `radius`:
    /// over every pixel of the corner (`WindowCorner.pixels`), in whole
    /// points, since AppKit keeps a window's frame on whole points.
    public static func reach(radius: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return 0 }
        return (CGFloat(WindowCorner.side(radius: radius, scale: scale)) / scale).rounded(.up)
    }

    /// The reach for a sidebar placed at `p`.
    public static func reach(for p: SidebarPlacement, radius: CGFloat) -> CGFloat {
        reach(radius: radius, scale: p.scale)
    }

    /// The panel's frame: the sidebar and, on the window's side, `reach`
    /// more over the window. Top and bottom stay the sidebar's, which are
    /// the window's (`SidebarGeometry.place`).
    public static func panel(for p: SidebarPlacement, reach: CGFloat) -> CGRect {
        var f = p.sidebar
        f.size.width += reach
        if p.side == .right { f.origin.x -= reach }
        return f
    }

    // MARK: - The panel's shape

    /// The panel's shape as rects in its own pixels (x right, y down from
    /// its top-left corner), each on whole pixel rows; a rect's width says
    /// how much of a pixel is covered. `width` by `height` pixels; `reach`
    /// pixels of it lie over the window on the side away from `side`.
    ///
    /// Beside a window: the sidebar's body, its two outer corners drawn as
    /// the window's own corner (`corner.window`), and at the seam the two
    /// notches (`corner.notch`). During a slide: only the strip from `reveal`
    /// (x in pixels) to the outer edge, no notches. A panel too small for
    /// its corners is a plain rect.
    public static func mask(width: Int, height: Int, side: SidebarSide, reach: Int, corner: CornerPixels, reveal: CGFloat?) -> [CGRect] {
        let w = CGFloat(width), n = corner.side
        // The body's span, and which of its ends (the outer one) is rounded.
        var x0: CGFloat = 0, x1 = w
        let left = side == .left, right = side == .right
        if side == .right { x0 = CGFloat(reach) } else { x1 = w - CGFloat(reach) }
        if let reveal {
            if side == .right { x0 = min(max(reveal, 0), w) } else { x1 = min(max(reveal, 0), w) }
            if x1 - x0 < 1 { return [] }
        }
        guard x1 > x0 else { return [] }
        guard n > 0, height >= 2 * n, x1 - x0 >= CGFloat((left ? n : 0) + (right ? n : 0)) || reveal != nil else {
            return [CGRect(x: x0, y: 0, width: x1 - x0, height: CGFloat(height))]
        }
        var rects: [CGRect] = []
        // Nothing leaves the span it belongs to: a slide's strip can be narrower than a corner.
        func add(_ x: CGFloat, _ y: Int, _ width: CGFloat, within lo: CGFloat, _ hi: CGFloat) {
            let a = max(x, lo), b = min(x + width, hi)
            if b > a { rects.append(CGRect(x: a, y: CGFloat(y), width: b - a, height: 1)) }
        }
        // Between the corner bands, and within them between the corners.
        rects.append(CGRect(x: x0, y: CGFloat(n), width: x1 - x0, height: CGFloat(height - 2 * n)))
        let inner0 = x0 + (left ? CGFloat(n) : 0), inner1 = x1 - (right ? CGFloat(n) : 0)
        if inner1 > inner0 {
            rects.append(CGRect(x: inner0, y: 0, width: inner1 - inner0, height: CGFloat(n)))
            rects.append(CGRect(x: inner0, y: CGFloat(height - n), width: inner1 - inner0, height: CGFloat(n)))
        }
        // A corner's pixels: `column` says where pixel `i` of a row lies.
        func block(_ grid: [[Double]], within lo: CGFloat, _ hi: CGFloat, column: (Int) -> CGFloat) {
            for j in 0..<n {
                for y in [j, height - 1 - j] {
                    var i = 0
                    while i < n {
                        let c = grid[j][i]
                        if c <= 0 { i += 1; continue }
                        if c < 1 {
                            add(column(i), y, CGFloat(c), within: lo, hi)
                            i += 1
                            continue
                        }
                        // A run of whole pixels as one rect.
                        var end = i
                        while end + 1 < n, grid[j][end + 1] >= 1 { end += 1 }
                        let a = column(i), b = column(end)
                        add(min(a, b), y, abs(b - a) + 1, within: lo, hi)
                        i = end + 1
                    }
                }
            }
        }
        if left { block(corner.window, within: x0, x1) { x0 + CGFloat($0) } }
        if right { block(corner.window, within: x0, x1) { x1 - 1 - CGFloat($0) } }
        if reveal == nil, reach >= n {
            // Pixel `i` of the notch lies `i` pixels into the window from the seam.
            if side == .right { block(corner.notch, within: 0, x0) { x0 - 1 - CGFloat($0) } }
            else { block(corner.notch, within: x1, w) { x1 + CGFloat($0) } }
        }
        return rects
    }
}
