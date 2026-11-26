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
    /// True when the sidebar sits over the window's edge instead of beside it
    /// (only when the browser refused to make room).
    public var overlaps: Bool
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
    /// the sidebar goes wherever the window does, off the screen too. With
    /// `keepOnScreen` (the browser refused to make room) it covers the
    /// window's edge instead.
    ///
    /// Each edge goes to the nearest pixel of a screen with `scale` pixels
    /// per point, the window's edges on their own: the sidebar's top, bottom
    /// and seam are the window's, to the pixel, on any scale.
    public static func place(window: CGRect, screen: CGRect, width: CGFloat,
                             side: SidebarSide, keepOnScreen: Bool = false, scale: CGFloat = 1) -> SidebarPlacement {
        let px = { (v: CGFloat) in SidebarSeam.aligned(v, scale: scale) }
        let minY = px(window.minY), maxY = px(window.maxY)
        let edge = px(side == .left ? window.minX : window.maxX)
        let outside = side == .left ? px(edge - width) : edge
        let w = side == .left ? edge - outside : px(edge + width) - edge
        let x = keepOnScreen ? min(max(outside, screen.minX), screen.maxX - w) : outside
        return SidebarPlacement(sidebar: CGRect(x: x, y: minY, width: w, height: max(0, maxY - minY)),
                                side: side, overlaps: x != outside, scale: scale)
    }

    /// The free width beside the window on the sidebar's side.
    public static func room(beside w: CGRect, screen: CGRect, side: SidebarSide) -> CGFloat {
        side == .left ? w.minX - screen.minX : screen.maxX - w.maxX
    }

    /// Whether going from `a` to `b` pushes the window off the screen: an edge
    /// that was on it is now past it.
    public static func leaves(_ screen: CGRect, from a: CGRect, to b: CGRect) -> Bool {
        (a.maxX <= screen.maxX + 2 && b.maxX > screen.maxX + 2) || (a.minX >= screen.minX - 2 && b.minX < screen.minX - 2)
    }

    /// The browser's minimum width, when its answer to being asked to narrow
    /// to `asked` shows one: it took the place asked and narrowed from
    /// `wasWidth`, but not as far as asked. A window as wide as before has not
    /// answered yet, or won't narrow: that width is no minimum.
    public static func minimumWidth(asked: CGRect, got: CGRect, wasWidth: CGFloat) -> CGFloat? {
        guard abs(got.minX - asked.minX) < 2, abs(got.height - asked.height) < 2,
              got.width > asked.width + 2, got.width < wasWidth - 2 else { return nil }
        return got.width
    }

    /// The narrowest and widest the sidebar gets.
    public static let widths: ClosedRange<CGFloat> = 200...440

    /// The sidebar's new width and the window's new frame when the edge
    /// between them is dragged so the sidebar would be `wanted` wide: the pair
    /// keeps its outer edges. The window never goes below `minWindowWidth`
    /// (one already narrower gives up nothing more).
    public static func resized(window w: CGRect, width: CGFloat, to wanted: CGFloat, side: SidebarSide,
                               minWindowWidth: CGFloat) -> (width: CGFloat, window: CGRect) {
        let most = min(widths.upperBound, width + max(0, w.width - minWindowWidth))
        let new = min(max(wanted, widths.lowerBound), max(most, widths.lowerBound)).rounded()
        var out = w
        out.size.width = w.width + width - new
        if side == .left { out.origin.x = w.minX + new - width }
        return (new, out)
    }

    /// The browser window's frame when the pair (window plus sidebar) is to
    /// fill `rect`, with the sidebar on `side` (left or right) keeping its
    /// `width`: what a snap or move aimed at the sidebar means. The window never
    /// goes below `minWindowWidth`; then it overflows `rect` away from the
    /// sidebar rather than covering it.
    public static func window(filling rect: CGRect, width: CGFloat, side: SidebarSide,
                              minWindowWidth: CGFloat = 0) -> CGRect {
        let r = rect.integral
        let w = max(r.width - width, minWindowWidth)
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
                                             side: SidebarSide, minWindowWidth: CGFloat = 0) -> CGRect {
        if abs(new.width - old.width) < 2 {
            return CGRect(x: w.minX + (new.minX - old.minX), y: new.minY, width: w.width, height: new.height).integral
        }
        return window(filling: new, width: width, side: side, minWindowWidth: minWindowWidth)
    }

    /// True when every edge of `w` lies on a half, third or quarter line of
    /// `screen` (the visible frame): the window was snapped, not placed by hand.
    /// The tolerance covers the gaps window managers leave around tiles.
    public static let snapTolerance: CGFloat = 10

    public static func isSnapped(_ w: CGRect, screen s: CGRect, tolerance: CGFloat = snapTolerance) -> Bool {
        snapError(w, screen: s) <= tolerance
    }

    /// How far the edge farthest from a half, third or quarter line is from one.
    static func snapError(_ w: CGRect, screen s: CGRect) -> CGFloat {
        guard s.width > 0, s.height > 0 else { return .infinity }
        let lines: [CGFloat] = [0, 1, 1 / 2, 1 / 3, 2 / 3, 1 / 4, 3 / 4]
        func off(_ v: CGFloat, _ origin: CGFloat, _ length: CGFloat) -> CGFloat {
            lines.map { abs(origin + $0 * length - v) }.min() ?? .infinity
        }
        return max(off(w.minX, s.minX, s.width), off(w.maxX, s.minX, s.width),
                   off(w.minY, s.minY, s.height), off(w.maxY, s.minY, s.height))
    }

    /// The frame a window that came to rest should take so that the window and
    /// its sidebar together behave as one window, or nil to leave it alone.
    ///
    /// - Snapped to a tile: the pair fills exactly that tile.
    /// - Placed by hand with too little room for the sidebar before the
    ///   screen's edge: the window gives up only what is missing.
    ///
    /// At the window's minimum width the pair is wider than the tile and shifts to stay on screen.
    public static func settled(window: CGRect, screen: CGRect, width: CGFloat, side: SidebarSide,
                               minWindowWidth: CGFloat = 500) -> CGRect? {
        let w = window.integral
        let room = room(beside: w, screen: screen, side: side)
        let need: CGFloat
        if isSnapped(w, screen: screen) {
            need = width
        } else if room >= 0, room < width {
            need = width - room
        } else {
            return nil // enough room, or the user dragged that edge off the screen
        }
        var out = w
        out.size.width = max(minWindowWidth, w.width - need)
        if side == .left {
            out.origin.x = w.minX + need
            out.origin.x = max(screen.minX + width, min(out.origin.x, screen.maxX - out.width))
        } else {
            out.origin.x = max(screen.minX, min(w.minX, screen.maxX - width - out.width))
        }
        // A browser too wide for the sidebar to fit beside it on this screen at
        // all keeps its place: never pushed off the screen's other edge.
        if leaves(screen, from: w, to: out) || out.width + width > screen.width + 2 { return nil }
        return out == w ? nil : out
    }
}

/// The windows the sidebar has narrowed, kept across launches. From its frame
/// alone a narrowed window can look freshly snapped (a half less the sidebar
/// can sit on the one-third line) and a freshly snapped one can look already
/// fitted, so whether a window was narrowed is remembered, not guessed. A
/// window is known by its window-server number, which stays the same for the
/// window's life (betterlink relaunching included) and is never shared, so
/// another window at the same frame is never mistaken for it.
public struct FitMemory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var bundleId: String
        /// The window's window-server number (CGWindowID).
        public var window: UInt32
        /// What the window was narrowed to, and the space it had before.
        public var inner: CGRect, outer: CGRect
        public init(bundleId: String, window: UInt32, inner: CGRect, outer: CGRect) {
            self.bundleId = bundleId; self.window = window; self.inner = inner; self.outer = outer
        }
    }

    public private(set) var entries: [Entry] = []
    public init(entries: [Entry] = []) { self.entries = entries }

    /// The record for this window when it is still exactly as narrowed.
    public func fitted(_ frame: CGRect, window: UInt32) -> Entry? {
        entries.last { $0.window == window && WidthLoan.same($0.inner, frame) }
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
