import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Where the betterlink sidebar goes next to a browser window. Pure math, so it
/// is unit tested; the app feeds it frames from the Accessibility API.
///
/// All rects are in Cocoa global coordinates (origin bottom-left of the main
/// screen, y up). `SidebarGeometry.cocoa(fromAX:mainScreenHeight:)` converts
/// the Accessibility API's top-left frames.
public enum SidebarSide: String, Codable, CaseIterable, Sendable {
    case left, right
}

public struct SidebarPlacement: Equatable, Sendable {
    /// Where the sidebar panel goes.
    public var sidebar: CGRect
    public var side: SidebarSide
    /// The pixels per point of the screen it was placed on.
    public var scale: CGFloat
}

public enum SidebarGeometry {
    /// Converts an Accessibility frame (top-left origin, y down from the top of
    /// the main screen) to Cocoa global coordinates.
    public static func cocoa(fromAX r: CGRect, mainScreenHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// The inverse: a Cocoa frame as an Accessibility position + size.
    public static func ax(fromCocoa r: CGRect, mainScreenHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Places a `width`-wide sidebar flush against the outside of `window`'s
    /// edge, the full height of the window. The pair moves like one window, so
    /// the sidebar goes wherever the window does, off the screen too.
    ///
    /// Each edge goes to the nearest pixel of a screen with `scale` pixels
    /// per point, the window's edges on their own: the sidebar's top, bottom
    /// and seam are the window's, to the pixel, on any scale.
    public static func place(window: CGRect, width: CGFloat, side: SidebarSide, scale: CGFloat = 1) -> SidebarPlacement {
        let px = { (v: CGFloat) in SidebarSeam.aligned(v, scale: scale) }
        let minY = px(window.minY), maxY = px(window.maxY)
        let edge = px(side == .left ? window.minX : window.maxX)
        let outside = side == .left ? px(edge - width) : edge
        let w = side == .left ? edge - outside : px(edge + width) - edge
        return SidebarPlacement(sidebar: CGRect(x: outside, y: minY, width: w, height: max(0, maxY - minY)),
                                side: side, scale: scale)
    }

    /// Frames within 2 pt count as the same: browsers round.
    public static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The browser's frame when its sidebar opens in `frame` (where the window
    /// was with the sidebar closed): the pair occupies that frame, the
    /// sidebar `width` wide on `side`, the browser the rest, its far edge
    /// where it was. Never narrower than a point: a browser asked for less
    /// stops where it can, and the sidebar has what is left.
    public static func opened(_ frame: CGRect, width: CGFloat, side: SidebarSide) -> CGRect {
        var b = frame
        b.size.width = max(1, frame.width - width)
        if side == .left { b.origin.x = frame.maxX - b.width }
        return b
    }

    /// The browser's frame when its sidebar closes: the pair's frame (the
    /// browser `browser`, the sidebar `width` wide beside it on `side`), moved
    /// as little as it takes to be on the displays side by side at its height
    /// (`displays`, whole frames): the browser never ends off screen. A pair
    /// wider than they are (the person widened the browser while the sidebar
    /// was open) fills them: macOS makes no window wider than its displays.
    public static func closed(browser b: CGRect, width: CGFloat, side: SidebarSide, displays: [CGRect]) -> CGRect {
        var p = b
        p.size.width += width
        if side == .left { p.origin.x -= width }
        guard let span = span(at: p, of: displays) else { return p }
        p.size.width = min(p.width, span.upperBound - span.lowerBound)
        if p.maxX > span.upperBound { p.origin.x = span.upperBound - p.width }
        if p.minX < span.lowerBound { p.origin.x = span.lowerBound }
        return p
    }

    /// The horizontal span of the display under most of `r` and of those
    /// touching it side by side at `r`'s height.
    public static func span(at r: CGRect, of displays: [CGRect]) -> ClosedRange<CGFloat>? {
        let level = displays.filter { $0.minY < r.maxY - 1 && $0.maxY > r.minY + 1 }
        guard let home = level.max(by: { $0.intersection(r).area < $1.intersection(r).area }) else { return nil }
        var lo = home.minX, hi = home.maxX
        var grew = true
        while grew {
            grew = false
            for d in level {
                if d.minX <= hi + 1, d.maxX > hi { hi = d.maxX; grew = true }
                if d.maxX >= lo - 1, d.minX < lo { lo = d.minX; grew = true }
            }
        }
        return lo...hi
    }

    /// The narrowest and widest the sidebar gets.
    public static let widths: ClosedRange<CGFloat> = 200...440

    /// The sidebar's new width and the window's new frame when the edge
    /// between them is dragged so the sidebar would be `wanted` wide: the pair
    /// keeps its outer edges. The browser is asked for what is left; what it
    /// really takes is read off its window.
    public static func resized(window w: CGRect, width: CGFloat, to wanted: CGFloat, side: SidebarSide) -> (width: CGFloat, window: CGRect) {
        let most = min(widths.upperBound, width + max(0, w.width - 1))
        let new = min(max(wanted, widths.lowerBound), max(most, widths.lowerBound)).rounded()
        var out = w
        out.size.width = w.width + width - new
        if side == .left { out.origin.x = w.minX + new - width }
        return (new, out)
    }

    /// The browser window's frame when the pair (window plus sidebar) is to
    /// fill `rect`, with the sidebar on `side` (left or right) keeping its
    /// `width`: what a snap or move aimed at the sidebar means.
    public static func window(filling rect: CGRect, width: CGFloat, side: SidebarSide) -> CGRect {
        let r = rect.integral
        let w = max(r.width - width, 1)
        let x = side == .left ? r.minX + width : r.maxX - width - w
        return CGRect(x: x, y: r.minY, width: w, height: r.height)
    }

    /// The browser window's frame after something outside moved or resized
    /// the sidebar panel from `old` to `new`. A move that keeps the panel's
    /// width (a plain move, "center", "maximize height") carries the pair: the
    /// window keeps its width and moves by as much as the panel did, taking the
    /// panel's new height. A new width means the panel was given a tile to
    /// fill, so the pair fills it (see `window(filling:)`).
    public static func windowAfterPanelMoved(from old: CGRect, to new: CGRect, window w: CGRect, width: CGFloat,
                                             side: SidebarSide) -> CGRect {
        if abs(new.width - old.width) < 2 {
            return CGRect(x: w.minX + (new.minX - old.minX), y: new.minY, width: w.width, height: new.height).integral
        }
        return window(filling: new, width: width, side: side)
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// The windows whose sidebar is open, narrowed for it, kept across launches:
/// from its frame alone a narrowed window can't be told from one that is
/// not, so a window found at a launch is narrowed again only when it isn't
/// one of these. A window is known by its window-server number, which stays
/// the same for the window's life (betterlink relaunching included) and is
/// never shared, so another window at the same frame is never mistaken for it.
public struct FitMemory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var bundleId: String
        /// The window's window-server number (CGWindowID).
        public var window: UInt32
        /// Where the window is with its sidebar open, and the pair's frame.
        public var inner: CGRect, outer: CGRect
        public init(bundleId: String, window: UInt32, inner: CGRect, outer: CGRect) {
            self.bundleId = bundleId; self.window = window; self.inner = inner; self.outer = outer
        }
    }

    public private(set) var entries: [Entry] = []
    public init(entries: [Entry] = []) { self.entries = entries }

    /// The record for this window when it is still where it was with its sidebar open.
    public func fitted(_ frame: CGRect, window: UInt32) -> Entry? {
        entries.last { $0.window == window && SidebarGeometry.same($0.inner, frame) }
    }

    public mutating func record(_ e: Entry) {
        entries.removeAll { $0.window == e.window }
        entries.append(e)
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
    }

    public mutating func forget(window: UInt32) { entries.removeAll { $0.window == window } }

    /// Drops the records of windows that no longer exist.
    public mutating func prune(alive: Set<UInt32>) { entries.removeAll { !alive.contains($0.window) } }
}
