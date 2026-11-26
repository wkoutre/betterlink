import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A drag of the edge between a sidebar and its browser window, decided from
/// where the window really is. The pair keeps the outer edges it had when the
/// drag began. The pointer only says how wide the sidebar is wanted: the
/// window is asked to make that room, and the sidebar is as wide as the room
/// the window has made.
///
/// A window that has not answered yet has not given the space yet, and one at
/// its browser's minimum width gives no more. Mid-drag the two look the same
/// (narrower than before, not as narrow as asked), so a drag learns no minimum
/// width, and needs none. The drag holds only while it lasts: a window that
/// answers after it has ended has been resized, as if by hand.
public struct EdgeDrag: Equatable, Sendable {
    /// The window, and how wide the sidebar was, when the drag began.
    public let window: CGRect
    public let width: CGFloat
    public let side: SidebarSide
    /// The sidebar covers the window's edge: only the sidebar changes.
    public let covers: Bool

    public init(window: CGRect, width: CGFloat, side: SidebarSide, covers: Bool = false) {
        self.window = window; self.width = width; self.side = side; self.covers = covers
    }

    /// The window's edge away from the sidebar, kept where it is for as long
    /// as the drag lasts. An answer that comes after the drag has ended is a
    /// resize by hand, and is not put back.
    public var farEdge: CGFloat { side == .left ? window.maxX : window.minX }

    /// The frame to ask the window for when the pointer wants the sidebar
    /// `delta` points wider than it was: the far edge where it is, the rest
    /// of the pair's width (`SidebarGeometry.resized`). Never below
    /// `minWindowWidth`, the width browsers are assumed to stop at; what this
    /// browser does is read off its window. Nil when the window is left alone.
    public func ask(delta: CGFloat, minWindowWidth: CGFloat = 500) -> CGRect? {
        if covers { return nil }
        return SidebarGeometry.resized(window: window, width: width, to: width + delta, side: side,
                                       minWindowWidth: minWindowWidth).window
    }

    /// The sidebar's width with the window seen at `real`: the room the
    /// window has made, whatever it was asked, in whole points within the
    /// sidebar's limits.
    public func width(delta: CGFloat, beside real: CGRect) -> CGFloat {
        if covers {
            return SidebarGeometry.resized(window: window, width: width, to: width + delta, side: side, minWindowWidth: 0).width
        }
        let limits = SidebarGeometry.widths
        return min(max((window.width + width - real.width).rounded(), limits.lowerBound), limits.upperBound)
    }

    /// Where a window seen at `real` belongs, at the width it has, when its
    /// far edge is not where the drag began: one told only its size keeps its
    /// left edge, and one that would not narrow may have moved instead. Nil
    /// when it is in place.
    public func kept(_ real: CGRect) -> CGRect? {
        if covers { return nil }
        var at = real
        at.origin.x = side == .left ? farEdge - real.width : farEdge
        return abs(at.minX - real.minX) < 2 ? nil : at
    }

    /// How long a single step (the edge's adjustable action, which has no
    /// button to come up) stays open for a window that has not answered,
    /// before it ends with what the window has given.
    public static let answerWait: TimeInterval = 0.3

    /// Whether a window seen at `real` has answered `ask`: it has the width
    /// asked. With nothing asked there is nothing to wait for.
    public func answered(_ ask: CGRect?, by real: CGRect) -> Bool {
        guard let ask else { return true }
        return abs(real.width - ask.width) < 2
    }

    /// The delta after one more single step of `step` points on a resize
    /// that stands at `delta`: steps taken before the window has answered add
    /// up. Counted from what is asked now, so steps past the sidebar's limits
    /// or the least width a window is asked for (`minWindowWidth`) don't pile
    /// up beyond them and one step back is felt at once. A browser's own,
    /// larger minimum isn't known here: steps past it add up until the wait
    /// ends, and the next step starts from the window as it is.
    public func stepped(_ delta: CGFloat, by step: CGFloat, minWindowWidth: CGFloat = 500) -> CGFloat {
        func within(_ d: CGFloat) -> CGFloat {
            SidebarGeometry.resized(window: window, width: width, to: width + d, side: side,
                                    minWindowWidth: covers ? 0 : minWindowWidth).width - width
        }
        return within(within(delta) + step)
    }

    /// What the window has lent once the drag is over, seen at `real`. The
    /// space it had before (`outer`, when it had lent some already) stays;
    /// one that had lent nothing lends what the drag took. Nil: nothing
    /// before, nothing now.
    public func loan(lent outer: CGRect?, at real: CGRect) -> WidthLoan? {
        guard outer != nil || real.width < window.width - 2 else { return nil }
        return .lent(outer: outer ?? window, inner: real, side: side)
    }
}
