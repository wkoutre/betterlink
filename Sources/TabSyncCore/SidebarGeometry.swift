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
    /// A new frame for the browser window when it must shrink or move to make
    /// room, else nil (leave the window alone).
    public var window: CGRect?
    /// The side actually used (resolves `.auto`).
    public var side: SidebarSide
    /// True when the sidebar sits over the window's edge instead of beside it
    /// (full-screen-sized windows with "make room" off).
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

    /// Places a `width`-wide sidebar flush against `window`'s edge, the full
    /// height of the window, inside `screen` (the visible frame of the screen
    /// the window is on).
    ///
    /// - `.left` / `.right`: that edge. `.auto`: the side with more free room,
    ///   right on a tie (the side people expect a sidebar of tools).
    /// - When there isn't room outside the window on that side: with
    ///   `makeRoom`, the window is narrowed (and shifted, for `.left`) so the
    ///   pair exactly fills the space; without it, the sidebar overlaps the
    ///   window's edge.
    public static func place(window: CGRect, screen: CGRect, width: CGFloat,
                             side: SidebarSide, makeRoom: Bool,
                             minWindowWidth: CGFloat = 500) -> SidebarPlacement {
        let w = window.integral
        let roomLeft = max(0, w.minX - screen.minX)
        let roomRight = max(0, screen.maxX - w.maxX)
        let resolved: SidebarSide = switch side {
        case .auto: roomLeft > roomRight ? .left : .right
        default: side
        }
        // Clip the window's vertical span to the screen so the sidebar never
        // runs under the menu bar or the Dock.
        let minY = max(w.minY, screen.minY)
        let maxY = min(w.maxY, screen.maxY)
        let height = max(0, maxY - minY)

        func beside(_ win: CGRect) -> CGRect {
            resolved == .left
                ? CGRect(x: win.minX - width, y: minY, width: width, height: height)
                : CGRect(x: win.maxX, y: minY, width: width, height: height)
        }

        let room = resolved == .left ? roomLeft : roomRight
        if room >= width {
            return SidebarPlacement(sidebar: beside(w), window: nil, side: resolved, overlaps: false)
        }
        if makeRoom {
            let need = width - room
            var nw = w
            nw.size.width = max(minWindowWidth, w.width - need)
            if resolved == .left {
                nw.origin.x = screen.minX + width
                // If narrowing hit the floor, the window keeps its width and
                // only moves; the pair may still run past the right edge.
            } else {
                nw.origin.x = min(w.minX, screen.maxX - width - nw.width)
                nw.origin.x = max(nw.origin.x, screen.minX)
            }
            if nw != w {
                return SidebarPlacement(sidebar: beside(nw), window: nw, side: resolved, overlaps: false)
            }
        }
        // No room and not allowed to make any: sit over the window's edge.
        let sb = resolved == .left
            ? CGRect(x: w.minX, y: minY, width: width, height: height)
            : CGRect(x: w.maxX - width, y: minY, width: width, height: height)
        return SidebarPlacement(sidebar: sb, window: nil, side: resolved, overlaps: true)
    }
}
