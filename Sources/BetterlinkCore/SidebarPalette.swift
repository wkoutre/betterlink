import Foundation

/// Colors for a sidebar painted in a browser profile's color, readable by WCAG
/// 2.2 AA: every text level (primary, secondary, tertiary) has at least 4.5:1
/// contrast with the background. The background keeps the profile's hue and
/// is darkened (or lightened, for a pale color) only as far as that needs,
/// which also tones down a strong theme color next to the browser's frame.
public struct SidebarPalette: Equatable, Sendable {
    public struct RGB: Equatable, Sendable {
        public var r, g, b: Double // 0...1, sRGB
        public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
        public init(hex: UInt32) {
            self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
        }
        public var hex: UInt32 {
            func c(_ v: Double) -> UInt32 { UInt32((min(max(v, 0), 1) * 255).rounded()) }
            return c(r) << 16 | c(g) << 8 | c(b)
        }
    }

    public var background: RGB
    /// Text and icons; the lower levels are this color at these opacities.
    public var foreground: RGB
    public static let secondaryOpacity = 0.85
    public static let tertiaryOpacity = 0.72
    /// Row fills: the foreground at low opacity.
    public static let hoverOpacity = 0.10
    public static let selectedOpacity = 0.18
    /// The minimum WCAG contrast for normal text (AA).
    public static let minimumContrast = 4.5

    public init(profileColor hex: UInt32) {
        let base = RGB(hex: hex)
        // White text on dark colors, near-black on pale ones: whichever reads better.
        let white = RGB(1, 1, 1), ink = RGB(0.07, 0.07, 0.08)
        let fg = Self.contrast(white, base) >= Self.contrast(ink, base) ? white : ink
        let (h, s, l0) = Self.hsl(base)
        var l = l0
        var bg = base
        // Step lightness away from the text until the faintest level passes.
        for _ in 0..<60 {
            if Self.contrast(Self.blend(fg, Self.tertiaryOpacity, over: bg), bg) >= Self.minimumContrast { break }
            l = fg == white ? max(0, l - 0.01) : min(1, l + 0.01)
            bg = Self.rgb(h, s, l)
        }
        background = bg
        foreground = fg
    }

    /// True when the text is light, so the system's dark scheme (its text
    /// fields, placeholders and labels) reads on this background.
    public var wantsDarkScheme: Bool { Self.luminance(foreground) > 0.5 }

    public func level(_ opacity: Double) -> RGB { Self.blend(foreground, opacity, over: background) }

    // MARK: - WCAG math

    static func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    /// WCAG contrast ratio, 1...21.
    public static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func blend(_ fg: RGB, _ alpha: Double, over bg: RGB) -> RGB {
        RGB(fg.r * alpha + bg.r * (1 - alpha), fg.g * alpha + bg.g * (1 - alpha), fg.b * alpha + bg.b * (1 - alpha))
    }

    static func hsl(_ c: RGB) -> (Double, Double, Double) {
        let mx = max(c.r, c.g, c.b), mn = min(c.r, c.g, c.b), l = (mx + mn) / 2
        guard mx != mn else { return (0, 0, l) }
        let d = mx - mn
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        switch mx {
        case c.r: h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0)
        case c.g: h = (c.b - c.r) / d + 2
        default: h = (c.r - c.g) / d + 4
        }
        h /= 6
        return (h, s, l)
    }

    static func rgb(_ h: Double, _ s: Double, _ l: Double) -> RGB {
        guard s > 0 else { return RGB(l, l, l) }
        func hue(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
        return RGB(hue(p, q, h + 1 / 3), hue(p, q, h), hue(p, q, h - 1 / 3))
    }
}
