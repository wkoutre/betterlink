import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The width a browser window lends the sidebar. The two are one window: the
/// sidebar shows by taking width from the browser, and hiding gives back what
/// was taken, wherever the window has been since.
public struct WidthLoan: Equatable, Sendable {
    /// What hiding gives the window.
    public var outer: CGRect
    /// The window while the sidebar is beside it.
    public var inner: CGRect
    public var side: SidebarSide

    public init(outer: CGRect, inner: CGRect, side: SidebarSide) {
        self.outer = outer; self.inner = inner; self.side = side
    }

    public var taken: CGFloat { max(0, outer.width - inner.width) }

    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// The loan after the window came to rest at `frame`; nil: it was snapped
    /// to a new tile, which the pair is to fill, so it is placed afresh.
    ///
    /// Right after being asked, a different frame is the browser's own rounding
    /// or minimum: what it lent is what is still missing from `outer`. Later it
    /// is the person moving or resizing the window, and the space goes with it.
    public func settled(at frame: CGRect, screen: CGRect, justAsked: Bool) -> WidthLoan? {
        if Self.same(inner, frame) { return self }
        if justAsked, Self.near(inner, frame) { return WidthLoan(outer: outer, inner: frame, side: side) }
        if Self.same(outer, frame) || SidebarGeometry.isSnapped(frame, screen: screen) { return nil }
        return following(frame)
    }

    /// The same width on the same side of a window now at `frame`.
    private func following(_ frame: CGRect) -> WidthLoan {
        var o = frame
        o.size.width += taken
        if side == .left { o.origin.x -= taken }
        return WidthLoan(outer: o, inner: frame, side: side)
    }

    /// Close enough to what was asked to be the browser's answer to it: its
    /// place on the far side, its height and its width, give or take.
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minY - b.minY) < 12 && abs(a.height - b.height) < 12 && abs(a.midX - b.midX) < 200 && abs(a.width - b.width) < 200
    }

    /// What the window becomes when the sidebar hides, from where it is now:
    /// wider by what it lent, on the sidebar's side, no further than its screen
    /// goes there. Its far edge stays where it is.
    public func givenBack(from frame: CGRect, screen: CGRect) -> CGRect {
        // Still at its full width: it lent nothing yet.
        guard !Self.same(outer, frame), let now = settled(at: frame, screen: screen, justAsked: false) else { return frame }
        let o = now.outer
        // Past the edge already: no further.
        let minX = side == .left ? max(o.minX, min(screen.minX, frame.minX)) : o.minX
        let maxX = side == .right ? min(o.maxX, max(screen.maxX, frame.maxX)) : o.maxX
        return CGRect(x: minX, y: o.minY, width: maxX - minX, height: o.height)
    }
}
