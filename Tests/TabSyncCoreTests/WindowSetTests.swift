import CoreGraphics
import Testing
@testable import TabSyncCore

/// A slide-over's one set: its calls' order, and what the window is between them.
@Suite struct WindowSetTests {
    private let full = CGRect(x: 0, y: 0, width: 2056, height: 1290)
    private let left = CGRect(x: 280, y: 0, width: 1776, height: 1290)
    private let right = CGRect(x: 0, y: 0, width: 1776, height: 1290)

    /// The far edge (away from `side`) of every frame between the calls:
    /// never inside where it ends (Chrome for Testing on macOS 26.5.2, 10 of
    /// 10 runs with the nudge: the far edge never came in).
    private func farIn(from seen: CGRect, to target: CGRect, side: SidebarSide, right edge: CGFloat) -> CGFloat {
        let calls = WindowSet.calls(from: seen, to: target, keep: side, right: edge)
        let frames = WindowSet.betweens(from: seen, calls: calls)
        return frames.map { side == .left ? target.maxX - $0.maxX : $0.minX - target.minX }.max() ?? 0
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

    /// Against the screen's right edge a size can't grow a window that is
    /// wholly on screen past it, but it can one already partly off (Chrome
    /// for Testing on macOS 26.5.2: at x 300, 1640 wide, right edge 1940 on a
    /// 1920 screen, a size of 1920 gave right edge 2220). So the window is
    /// nudged 1 pt right first, its far edge 1 pt off the screen; then the
    /// size, which grows it past the edge; then the position. The far edge
    /// never comes in (live, the frames between were 281 1640 wide, 281 1920
    /// wide, then 0 1920 wide); the near edge moves 1 pt, under the panel.
    @Test func aLeftHideAgainstTheEdgeNudgesItOffThenSizesThenPlaces() {
        let calls = WindowSet.calls(from: left, to: full, keep: .left, right: 2056)
        #expect(calls == [.position(CGRect(x: 281, y: 0, width: 1776, height: 1290)), .size(full), .position(full)])
        #expect(WindowSet.betweens(from: left, calls: calls) == [CGRect(x: 281, y: 0, width: 1776, height: 1290), CGRect(x: 281, y: 0, width: 2056, height: 1290)])
        #expect(farIn(from: left, to: full, side: .left, right: 2056) < 0)
        #expect(farIn(from: left, to: full, side: .left, right: 2056) < 0.5)
        #expect(WindowSet.nudge(from: left, to: full, keep: .left, right: 2056) == 1)
        // Where it can grow in place, and for a show, there is no nudge and nothing comes in.
        let open = CGRect(x: 580, y: 0, width: 920, height: 1290), closed = CGRect(x: 300, y: 0, width: 1200, height: 1290)
        #expect(farIn(from: open, to: closed, side: .left, right: 2056) < 0.5)
        #expect(WindowSet.nudge(from: open, to: closed, keep: .left, right: 2056) == nil)
        #expect(farIn(from: full, to: left, side: .left, right: 2056) < 0.5)
    }

    /// Short of the screen's right edge, but too near it to grow in place:
    /// first the size that takes it to the edge (its far edge out), then the
    /// nudge, the size and the position as against the edge.
    @Test func aLeftHideNearTheEdgeGrowsToItFirst() {
        let open = CGRect(x: 1200, y: 0, width: 800, height: 1290), closed = CGRect(x: 920, y: 0, width: 1080, height: 1290)
        let calls = WindowSet.calls(from: open, to: closed, keep: .left, right: 2056)
        #expect(calls == [.size(CGRect(x: 1200, y: 0, width: 856, height: 1290)), .position(CGRect(x: 1201, y: 0, width: 856, height: 1290)),
                          .size(closed), .position(closed)])
        #expect(farIn(from: open, to: closed, side: .left, right: 2056) < 0)
        #expect(farIn(from: open, to: closed, side: .left, right: 2056) < 0.5)
    }

    /// A window already partly off the screen's right edge grows past it:
    /// the size, then the position, no nudge.
    @Test func aLeftHideAlreadyPartlyOffIsTheSizeThenThePosition() {
        let open = CGRect(x: 1500, y: 0, width: 800, height: 1290), closed = CGRect(x: 1220, y: 0, width: 1080, height: 1290)
        #expect(WindowSet.calls(from: open, to: closed, keep: .left, right: 2056) == [.size(closed), .position(closed)])
        #expect(WindowSet.nudge(from: open, to: closed, keep: .left, right: 2056) == nil)
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
