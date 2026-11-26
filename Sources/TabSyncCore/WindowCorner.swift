import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The corner the window server draws on a window whose corner radius it
/// reports as `radius`, pixel by pixel. Pure, so it is unit tested.
///
/// The outline is measured, not a formula: no API hands the shape out, and it
/// is not the continuous curve a CALayer draws for that radius (up to 0.4 of
/// a pixel fuller along the curve, with a long straight tail into each
/// edge). Nor is one radius's outline another's scaled: the 20 pt one scaled
/// to 16 is up to 0.15 of a pixel off a 16 pt window's corner. So each
/// radius measured has its own (`Outline`), and every other radius gets the
/// nearest one scaled. For 16, 20 and 26 that gives the edge straight 35, 46
/// and 64 pixels from the corner at 2x, where captures of such windows
/// measured 35, 46 and 63 (WindowCornerTests has the captures and the table).
public enum WindowCorner {
    /// A corner's outline read from the alpha of a single-window capture
    /// (`screencapture -o -l`, no shadow): each pixel row j below the
    /// diagonal gives a point (the row's uncovered area, j + 0.5) in pixels;
    /// the outline starts where those rows' line crosses the diagonal and
    /// ends where the last two partly covered rows' line reaches the edge.
    /// In radii, so it scales.
    struct Outline {
        /// The radius the window server reported for the window measured.
        let radius: CGFloat
        /// The half of the outline from the diagonal down to the side edge, in
        /// radii: (inset from the side edge, depth from the top edge). The other
        /// half is its mirror image.
        let half: [(CGFloat, CGFloat)]

        /// How far the curve runs along each edge, in radii.
        var run: CGFloat { half[half.count - 1].1 }

        /// The whole outline: (inset, depth) with the depth rising from the top edge.
        var points: [(inset: CGFloat, depth: CGFloat)] {
            half.dropFirst().reversed().map { (inset: $0.1, depth: $0.0) } + half.map { (inset: $0.0, depth: $0.1) }
        }
    }

    /// A Chrome 158 window, radius 20 (Chrome's and Brave's), macOS 26.5.2,
    /// 2x display, captured 2026-11-25; all four corners and Brave's the same.
    static let chrome20 = Outline(radius: 20, half: [
        (0.2977, 0.2977), (0.2830, 0.3125), (0.2601, 0.3375), (0.2383, 0.3625), (0.2171, 0.3875), (0.1957, 0.4125), (0.1816, 0.4375),
        (0.1654, 0.4625), (0.1469, 0.4875), (0.1370, 0.5125), (0.1212, 0.5375), (0.1125, 0.5625), (0.0977, 0.5875), (0.0917, 0.6125),
        (0.0824, 0.6375), (0.0724, 0.6625), (0.0675, 0.6875), (0.0604, 0.7125), (0.0517, 0.7375), (0.0475, 0.7625), (0.0443, 0.7875),
        (0.0403, 0.8125), (0.0357, 0.8375), (0.0304, 0.8625), (0.0249, 0.8875), (0.0241, 0.9125), (0.0230, 0.9375), (0.0219, 0.9625),
        (0.0206, 0.9875), (0.0192, 1.0125), (0.0178, 1.0375), (0.0166, 1.0625), (0.0154, 1.0875), (0.0141, 1.1125), (0.0131, 1.1375),
        (0.0121, 1.1625), (0.0111, 1.1875), (0.0101, 1.2125), (0.0093, 1.2375), (0.0083, 1.2625), (0.0075, 1.2875), (0.0066, 1.3125),
        (0.0057, 1.3375), (0.0048, 1.3625), (0.0039, 1.3875), (0.0030, 1.4125), (0.0022, 1.4375), (0.0014, 1.4625), (0.0008, 1.4875),
        (0.0, 1.5208),
    ])

    /// A Chrome for Testing window opened with `--app`, radius 16, macOS
    /// 26.5.2, 2x display, captured 2026-11-26; all four corners the same,
    /// and the same again with the window moved.
    static let app16 = Outline(radius: 16, half: [
        (0.2984, 0.2984), (0.2697, 0.3281), (0.2411, 0.3594), (0.2138, 0.3906), (0.1940, 0.4219), (0.1738, 0.4531), (0.1507, 0.4844),
        (0.1369, 0.5156), (0.1190, 0.5469), (0.1075, 0.5781), (0.0906, 0.6094), (0.0835, 0.6406), (0.0730, 0.6719), (0.0605, 0.7031),
        (0.0564, 0.7344), (0.0505, 0.7656), (0.0436, 0.7969), (0.0352, 0.8281), (0.0303, 0.8594), (0.0288, 0.8906), (0.0268, 0.9219),
        (0.0248, 0.9531), (0.0227, 0.9844), (0.0206, 1.0156), (0.0186, 1.0469), (0.0167, 1.0781), (0.0151, 1.1094), (0.0135, 1.1406),
        (0.0123, 1.1719), (0.0109, 1.2031), (0.0097, 1.2344), (0.0086, 1.2656), (0.0074, 1.2969), (0.0062, 1.3281), (0.0051, 1.3594),
        (0.0039, 1.3906), (0.0028, 1.4219), (0.0017, 1.4531), (0.0010, 1.4844), (0.0, 1.5260),
    ])

    static let measured = [chrome20, app16]

    /// The outline a window of corner radius `radius` gets: the measured one
    /// nearest it, scaled; halfway between two, the larger's. Nearest, not
    /// a blend of the two: a blend is a shape no capture showed, and with two
    /// radii measured nothing could check it. Each measured radius gets
    /// exactly the corner measured on it, and 20 and above stay Chrome's.
    static func outline(radius: CGFloat) -> Outline {
        measured.min { (abs($0.radius - radius), -$0.radius) < (abs($1.radius - radius), -$1.radius) } ?? chrome20
    }

    /// How far the 20 pt outline's curve runs along each edge, in radii:
    /// the fallback radius's (`SidebarSeam.fallbackRadius`). The others' are
    /// `outline(radius:).run`.
    public static var run: CGFloat { chrome20.run }

    /// How many pixels a side the corner takes: every pixel the curve
    /// touches, and the notch's inset more.
    public static func side(radius: CGFloat, scale: CGFloat) -> Int {
        radius > 0 && scale > 0 ? Int((outline(radius: radius).run * radius * scale).rounded(.up)) + SidebarSeam.notchInset : 0
    }

    /// The corner of a window with corner radius `radius` (points) on a
    /// screen with `scale` pixels per point, the window's corner point on a
    /// pixel's corner.
    public static func pixels(radius: CGFloat, scale: CGFloat) -> CornerPixels {
        let k = radius * scale
        let pts = outline(radius: radius).points.map { (u: $0.inset * k, v: $0.depth * k) }
        let n = side(radius: radius, scale: scale)
        guard n > 0 else { return CornerPixels(window: []) }
        // How far in the outline is at depth `v` (pixels): straight between the points.
        func inset(_ v: CGFloat) -> CGFloat {
            guard v < pts[pts.count - 1].v else { return 0 }
            guard let i = pts.firstIndex(where: { $0.v > v }), i > 0 else { return pts[0].u }
            let a = pts[i - 1], b = pts[i]
            return a.u + (b.u - a.u) * (v - a.v) / (b.v - a.v)
        }
        var window = Array(repeating: Array(repeating: 1.0, count: n), count: n)
        for j in 0..<n {
            // The row in pieces on which the outline is one straight line.
            let top = CGFloat(j), bottom = CGFloat(j + 1)
            let cuts = [top] + pts.map(\.v).filter { $0 > top && $0 < bottom } + [bottom]
            var clear = Array(repeating: 0.0, count: n)
            for (a, b) in zip(cuts, cuts.dropFirst()) {
                let fa = inset(a), fb = inset(b)
                for i in 0..<n where max(fa, fb) > CGFloat(i) {
                    // The area of this pixel's piece that is outside the window.
                    clear[i] += Double(abs(fb - fa) < 1e-12 ? (b - a) * min(max(fa - CGFloat(i), 0), 1)
                                                            : (b - a) / (fb - fa) * (area(fb, i) - area(fa, i)))
                }
            }
            for i in 0..<n {
                // Whole where it is whole to the eye: a pixel is then covered or it isn't.
                let a = 1 - clear[i]
                window[j][i] = a >= CornerPixels.opaque ? 1 : a <= 1 - CornerPixels.opaque ? 0 : a
            }
        }
        return CornerPixels(window: window)
    }

    /// The integral of how much of pixel column `i` lies left of x, up to `x`.
    private static func area(_ x: CGFloat, _ i: Int) -> CGFloat {
        let d = x - CGFloat(i)
        return d <= 0 ? 0 : d < 1 ? d * d / 2 : d - 0.5
    }
}

/// A window's corner on a screen's pixels, and the sidebar's fill for it at
/// the seam. `window[row][column]`: how much of that pixel the window covers,
/// 0 to 1; row 0 is at the edge the corner is on, column 0 at the corner.
public struct CornerPixels: Equatable, Sendable {
    /// From here a pixel counts as fully covered: it rounds to 255 of 255.
    public static let opaque = 1 - 1.0 / 510

    /// Pixels a side.
    public let side: Int
    public let window: [[Double]]
    /// How much of each pixel the sidebar covers where it is drawn over this
    /// corner of its window: all of every pixel the window doesn't fully
    /// cover, and beyond those the window's own edge moved
    /// `SidebarSeam.notchInset` pixels into the window on both axes.
    ///
    /// The sidebar's edge then lies only over pixels the window fully
    /// covers, and the window's edge only under pixels the sidebar fully
    /// covers: no pixel shows the desktop. Cut along the window's own edge
    /// instead (sidebar coverage 1 - a over window coverage a), a(1 - a) of
    /// the desktop shows through each edge pixel, up to a quarter.
    public let notch: [[Double]]

    public init(window: [[Double]]) {
        side = window.count
        self.window = window
        let d = SidebarSeam.notchInset
        notch = window.indices.map { j in
            window[j].indices.map { i in
                if window[j][i] < Self.opaque { return 1 }
                return i >= d && j >= d ? 1 - window[j - d][i - d] : 0
            }
        }
    }

    /// The rows from the corner until the window's edge is straight: the
    /// first pixel of each row before that is covered `alpha` or less. What
    /// a capture of the window measures.
    public func straightAfter(over alpha: Double = 127.0 / 255) -> Int {
        (window.lastIndex { ($0.first ?? 1) <= alpha } ?? -1) + 1
    }
}
