import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Showing and hiding the sidebar as one slide with the browser window (Nick,
/// 2026-11-24). The sidebar's outer edge (the screen side) stays put; its
/// inner edge and the window's edge move together, so the seam never opens
/// or overlaps. Hidden, the window fills the whole tile; shown, the pair does.
public struct SidebarSlide: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case shown, hidden, showing, hiding }

    public static let duration = 0.22

    public private(set) var phase: Phase
    private var from: Double, to: Double, start: Double, length: Double

    public init(shown: Bool) {
        phase = shown ? .shown : .hidden
        from = shown ? 1 : 0; to = from; start = 0; length = 0
    }

    /// How shown the sidebar is at `t`: 0 hidden, 1 shown, easing in and out.
    public func progress(at t: Double) -> Double {
        guard length > 0 else { return to }
        let f = min(max((t - start) / length, 0), 1)
        let eased = f < 0.5 ? 4 * f * f * f : 1 - pow(-2 * f + 2, 3) / 2
        return from + (to - from) * eased
    }

    public func done(at t: Double) -> Bool { length <= 0 || t - start >= length - 1e-9 }

    /// Starts showing at `t` from wherever the slide is (a show during a hide
    /// turns back from there). Reduce Motion: shown at once.
    public mutating func show(at t: Double, reduceMotion: Bool) {
        guard phase == .hidden || phase == .hiding else { return }
        retarget(1, at: t, reduceMotion: reduceMotion)
        phase = reduceMotion ? .shown : .showing
    }

    public mutating func hide(at t: Double, reduceMotion: Bool) {
        guard phase == .shown || phase == .showing else { return }
        retarget(0, at: t, reduceMotion: reduceMotion)
        phase = reduceMotion ? .hidden : .hiding
    }

    public mutating func settle(at t: Double) {
        guard done(at: t) else { return }
        if phase == .showing { phase = .shown }
        if phase == .hiding { phase = .hidden }
        from = to; length = 0
    }

    private mutating func retarget(_ target: Double, at t: Double, reduceMotion: Bool) {
        let now = progress(at: t)
        from = now; to = target; start = t
        length = reduceMotion ? 0 : SidebarSlide.duration * abs(target - now)
    }

    /// The frames at `progress` p for a sidebar `width` wide whose outer edge
    /// is at `outerEdge` on `side`. With a window that gives the sidebar room
    /// (`hiddenWindow` and `shownWindow` differ), the window's seam edge is
    /// exactly the sidebar's inner edge. Otherwise the window stays put and
    /// only the sidebar's inner edge moves. Cocoa coordinates.
    public static func frames(hiddenWindow: CGRect, shownWindow: CGRect, outerEdge: CGFloat, width: CGFloat,
                              side: SidebarSide, progress p: Double) -> (window: CGRect, innerEdge: CGFloat) {
        let q = CGFloat(min(max(p, 0), 1))
        let inner = side == .left ? outerEdge + width * q : outerEdge - width * q
        guard hiddenWindow != shownWindow else { return (hiddenWindow, inner) }
        // No further out than the window gets back: one that lent less than the
        // sidebar's width stops there while the sidebar's edge goes on. The far
        // edge goes from the hidden window's to the shown one's: the same
        // place, unless the shown window is the narrowest asked of a browser
        // and the pair shifts to fit, and then the window ends exactly there.
        var w = hiddenWindow
        if side == .left {
            let far = hiddenWindow.maxX + (shownWindow.maxX - hiddenWindow.maxX) * q
            w.origin.x = max(inner, hiddenWindow.minX); w.size.width = far - w.origin.x
        } else {
            let far = hiddenWindow.minX + (shownWindow.minX - hiddenWindow.minX) * q
            w.origin.x = far; w.size.width = min(inner, hiddenWindow.maxX) - far
        }
        return (w, inner)
    }

    /// Where the sidebar is revealed up to, given where the window's seam edge
    /// really is (`windowEdge`), where this moment of the slide puts the
    /// sidebar's inner edge, and the window's edge at its full width.
    public static func seam(windowEdge: CGFloat, innerEdge: CGFloat, hiddenEdge: CGFloat, side: SidebarSide) -> CGFloat {
        // The window's real edge, however late the browser is: the sidebar
        // never runs ahead of it. Past the window's full width, where the
        // window never goes, the sidebar goes on alone once the window is there.
        let past = side == .left ? innerEdge < hiddenEdge : innerEdge > hiddenEdge
        return past && abs(windowEdge - hiddenEdge) <= 1 ? innerEdge : windowEdge
    }
}
