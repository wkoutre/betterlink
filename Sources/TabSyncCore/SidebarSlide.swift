import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Showing and hiding the sidebar as a slide (Nick, 2026-11-24). The
/// sidebar's outer edge stays put and its inner edge moves, never past where
/// the browser window really is, so the seam never opens or overlaps.
public struct SidebarSlide: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case shown, hidden, showing, hiding }

    public static let duration = 0.22
    /// A hide's slide out begins once the window server has shown the
    /// browser at its frame for this long: a display frame (60 Hz's, the
    /// longer of the two), so the panel never uncovers it before it is there.
    public static let landedMargin = 1.0 / 60
    /// The longest a hide's slide out waits for that, after its calls are over.
    public static let landedWait = 0.15

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

    /// Where the sidebar's inner edge is at `progress` p, for a sidebar
    /// `width` wide whose outer edge is at `outerEdge` on `side`. The browser
    /// is not moved frame by frame: it is moved by `WindowSteps`, and the
    /// sidebar shows only up to where the browser really is (`seam`).
    public static func innerEdge(outerEdge: CGFloat, width: CGFloat, side: SidebarSide, progress p: Double) -> CGFloat {
        let q = CGFloat(min(max(p, 0), 1))
        return side == .left ? outerEdge + width * q : outerEdge - width * q
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
