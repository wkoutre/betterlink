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
    case left, right, auto
}

public struct SidebarPlacement: Equatable, Sendable {
    /// Where the sidebar panel goes.
    public var sidebar: CGRect
    /// The side actually used (resolves `.auto`).
    public var side: SidebarSide
    /// True when the sidebar sits over the window's edge instead of beside it
    /// (only when the browser refused to make room).
    public var overlaps: Bool
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

    /// `.auto`: the side with more free room, right on a tie.
    public static func resolve(_ side: SidebarSide, window w: CGRect, screen: CGRect) -> SidebarSide {
        guard side == .auto else { return side }
        return max(0, w.minX - screen.minX) > max(0, screen.maxX - w.maxX) ? .left : .right
    }

    /// Places a `width`-wide sidebar flush against the outside of `window`'s
    /// edge, the full height of the window. The pair moves like one window, so
    /// while it is dragged the sidebar may run off the screen. With
    /// `keepOnScreen` (the browser refused to make room) it covers the
    /// window's edge instead.
    public static func place(window: CGRect, screen: CGRect, width: CGFloat,
                             side: SidebarSide, keepOnScreen: Bool = false) -> SidebarPlacement {
        let w = window.integral
        let resolved = resolve(side, window: w, screen: screen)
        // Clip the vertical span so the sidebar never runs under the menu bar or the Dock.
        let minY = max(w.minY, screen.minY)
        let height = max(0, min(w.maxY, screen.maxY) - minY)
        let outside = resolved == .left ? w.minX - width : w.maxX
        let x = keepOnScreen ? min(max(outside, screen.minX), screen.maxX - width) : outside
        return SidebarPlacement(sidebar: CGRect(x: x, y: minY, width: width, height: height),
                                side: resolved, overlaps: x != outside)
    }

    /// True when every edge of `w` lies on a half, third or quarter line of
    /// `screen` (the visible frame): the window was snapped, not placed by hand.
    /// The tolerance covers the gaps window managers leave around tiles.
    public static func isSnapped(_ w: CGRect, screen s: CGRect, tolerance: CGFloat = 10) -> Bool {
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
        let resolved = resolve(side, window: w, screen: screen)
        let room = resolved == .left ? w.minX - screen.minX : screen.maxX - w.maxX
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
        if resolved == .left {
            out.origin.x = w.minX + need
            out.origin.x = max(screen.minX + width, min(out.origin.x, screen.maxX - out.width))
        } else {
            out.origin.x = max(screen.minX, min(w.minX, screen.maxX - width - out.width))
        }
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

    /// Frames within a point count as the same: browsers round.
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The record for this window when it is still exactly as narrowed.
    public func fitted(_ frame: CGRect, window: UInt32) -> Entry? {
        entries.last { $0.window == window && Self.same($0.inner, frame) }
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
