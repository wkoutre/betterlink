import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The width a browser window lends the sidebar. The two are one window: the
/// sidebar shows by taking width from the browser, and hiding gives back what
/// was taken, wherever the window has been since.
///
/// It holds only what was seen. Asking a window to narrow lends nothing; the
/// window being narrower does, whenever that happens.
public struct WidthLoan: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Asked to narrow; still as wide as it was.
        case asked
        /// Narrower by `taken`.
        case lent
    }
    public private(set) var phase: Phase
    /// The window without the sidebar: what hiding gives it.
    public private(set) var outer: CGRect
    /// Asked: where it was asked to go. Lent: where it is.
    public private(set) var inner: CGRect
    public let side: SidebarSide

    /// A window at `outer`, asked to go to `inner`.
    public static func asking(outer: CGRect, inner: CGRect, side: SidebarSide) -> WidthLoan {
        WidthLoan(phase: .asked, outer: outer, inner: inner, side: side)
    }
    /// A window known to have been narrowed from `outer` to `inner`.
    public static func lent(outer: CGRect, inner: CGRect, side: SidebarSide) -> WidthLoan {
        WidthLoan(phase: .lent, outer: outer, inner: inner, side: side)
    }

    /// What it has really lent.
    public var taken: CGFloat { phase == .lent ? max(0, outer.width - inner.width) : 0 }

    public static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    public struct Seen: Equatable, Sendable {
        /// Nil: the loan ended; place the window afresh.
        public var loan: WidthLoan?
        /// Where the window should be instead: it narrowed from the wrong side.
        public var correction: CGRect?
    }

    /// The loan now that the window is seen at `frame`.
    public func seen(at frame: CGRect, screen: CGRect) -> Seen {
        switch phase {
        case .asked:
            if Self.same(frame, outer) { return Seen(loan: self) } // not yet, or never
            // Narrower, in the space it was asked to leave part of: its answer,
            // early or late. Anything else is the person's doing: nothing was lent.
            guard frame.width < outer.width - 2, abs(frame.minY - outer.minY) < 12, abs(frame.height - outer.height) < 12,
                  frame.minX > min(outer.minX, inner.minX) - 12, frame.maxX < max(outer.maxX, inner.maxX) + 12 else { return Seen(loan: nil) }
            // The far edge stays: one that kept its sidebar-side edge instead is
            // put where its width belongs. A pair shifted to fit is where it was asked.
            var at = frame
            at.origin.x = side == .left ? max(outer.maxX, inner.maxX) - frame.width : min(outer.minX, inner.minX)
            let off = !Self.same(at, frame)
            return Seen(loan: .lent(outer: outer, inner: off ? at : frame, side: side), correction: off ? at : nil)
        case .lent:
            if Self.same(frame, inner) { return Seen(loan: self) }
            // Back at full width, or snapped to a new tile: that is the pair's now.
            if Self.same(frame, outer) || SidebarGeometry.isSnapped(frame, screen: screen) { return Seen(loan: nil) }
            // Moved or resized: the space goes with it.
            var o = frame
            o.size.width += taken
            if side == .left { o.origin.x -= taken }
            return Seen(loan: .lent(outer: o, inner: frame, side: side))
        }
    }

    /// The same loan for a pair moved as one.
    public func moved(by dx: CGFloat, to frame: CGRect) -> WidthLoan {
        var o = outer
        o.origin.x += dx; o.origin.y = frame.minY; o.size.height = frame.height
        return WidthLoan(phase: phase, outer: o, inner: frame, side: side)
    }

    /// What the window becomes when the sidebar hides, from where it is now:
    /// wider by what it lent, on the sidebar's side, no further than its screen
    /// goes there. Its far edge stays where it is.
    public func givenBack(from frame: CGRect, screen: CGRect) -> CGRect {
        guard let now = seen(at: frame, screen: screen).loan, now.phase == .lent else { return frame }
        let o = now.outer
        // Past the edge already: no further.
        let minX = side == .left ? max(o.minX, min(screen.minX, now.inner.minX)) : o.minX
        let maxX = side == .right ? min(o.maxX, max(screen.maxX, now.inner.maxX)) : o.maxX
        return CGRect(x: minX, y: o.minY, width: maxX - minX, height: o.height)
    }
}
