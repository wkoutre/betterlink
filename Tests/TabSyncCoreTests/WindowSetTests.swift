import CoreGraphics
import Testing
@testable import TabSyncCore

/// A slide-over's one set: its calls' order, and what the window is between them.
@Suite struct WindowSetTests {
    private let full = CGRect(x: 0, y: 0, width: 2056, height: 1290)
    private let left = CGRect(x: 280, y: 0, width: 1776, height: 1290)
    private let right = CGRect(x: 0, y: 0, width: 1776, height: 1290)

    /// The far edge (away from `side`) of the frame between the calls: never
    /// inside where it ends, except where a window must widen against the
    /// right edge of its screen.
    private func farIn(from seen: CGRect, to target: CGRect, side: SidebarSide, right edge: CGFloat) -> CGFloat {
        let calls = WindowSet.calls(from: seen, to: target, keep: side, right: edge)
        guard let b = WindowSet.between(from: seen, calls: calls) else { return 0 }
        return side == .left ? target.maxX - b.maxX : b.minX - target.minX
    }

    /// A left show: the position, then the size; the frame between pushed out past the screen's edge.
    @Test func aLeftShowIsThePositionThenTheSize() {
        let calls = WindowSet.calls(from: full, to: left, keep: .left, right: 2056)
        #expect(calls == [.position(left), .size(left)])
        #expect(WindowSet.between(from: full, calls: calls) == CGRect(x: 280, y: 0, width: 2056, height: 1290))
        #expect(farIn(from: full, to: left, side: .left, right: 2056) < 0)
    }

    /// A left hide where the window can grow from where it is: the size, then the position.
    @Test func aLeftHideThatFitsIsTheSizeThenThePosition() {
        let open = CGRect(x: 580, y: 0, width: 920, height: 1290), closed = CGRect(x: 300, y: 0, width: 1200, height: 1290)
        let calls = WindowSet.calls(from: open, to: closed, keep: .left, right: 2056)
        #expect(calls == [.size(closed), .position(closed)])
        #expect(farIn(from: open, to: closed, side: .left, right: 2056) < 0)
    }

    /// Against the screen's right edge a size can't grow the window past it:
    /// the position first, then the size, and for the frame between the far
    /// edge is in by the sidebar's width (the one place it can come in).
    @Test func aLeftHideAgainstTheEdgeIsThePositionThenTheSize() {
        let calls = WindowSet.calls(from: left, to: full, keep: .left, right: 2056)
        #expect(calls == [.position(full), .size(full)])
        #expect(farIn(from: left, to: full, side: .left, right: 2056) == 280)
    }

    /// On the right the window keeps its left edge: a size alone, either way.
    @Test func aRightShowOrHideIsASizeAlone() {
        #expect(WindowSet.calls(from: full, to: right, keep: .right, right: 2056) == [.size(right)])
        #expect(WindowSet.calls(from: right, to: full, keep: .right, right: 2056) == [.size(full)])
    }

    /// A pair moved back on screen as it closes (its far edge not kept, the
    /// right sidebar's window off the screen's left edge): widening, the
    /// position first, so the frame between is never further off screen.
    @Test func aFrameWhoseFarEdgeMovesGoesAsTheStepsWould() {
        let open = CGRect(x: -521, y: 45, width: 411, height: 1509), closed = CGRect(x: 0, y: 45, width: 679, height: 1509)
        let calls = WindowSet.calls(from: open, to: closed, keep: .right, right: 1406)
        #expect(calls == [.position(closed), .size(closed)])
        #expect(WindowSet.between(from: open, calls: calls) == CGRect(x: 0, y: 45, width: 411, height: 1509))
    }

    /// Nothing to change, nothing sent; a whole frame expands as `calls` orders it.
    @Test func nothingToChangeSendsNothing() {
        #expect(WindowSet.calls(from: full, to: full, keep: .left, right: 2056).isEmpty)
        #expect(WindowSet.expand(.frame(left), from: full, keep: .left, right: 2056) == [.position(left), .size(left)])
        #expect(WindowSet.expand(.size(left), from: full, keep: .left, right: 2056) == [.size(left)])
    }
}
