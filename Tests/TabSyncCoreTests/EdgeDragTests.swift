import CoreGraphics
import Testing
@testable import TabSyncCore

/// Dragging the edge between a sidebar and its window. Each test plays the
/// browser: what it is asked, what it does, and how wide the sidebar then is.
@Suite struct EdgeDragTests {
    /// A browser window as a drag meets it. Told a size, it keeps its left
    /// edge, goes no narrower than `least`, and may take its time.
    private struct Browser {
        var frame: CGRect
        var least: CGFloat = 500
        /// A width it was asked for and has not taken yet.
        var pending: CGFloat?

        mutating func size(_ width: CGFloat) { frame.size.width = max(least, width) }
        mutating func answer() {
            if let p = pending { size(p) }
            pending = nil
        }
    }

    private let tile = CGRect(x: 0, y: 0, width: 1280, height: 900)

    /// A window `width` wide with a 280 pt sidebar beside it, the pair ending
    /// at the tile's edge on the sidebar's side.
    private func start(_ side: SidebarSide, window width: CGFloat = 1000) -> EdgeDrag {
        EdgeDrag(window: CGRect(x: side == .left ? 280 : 1000 - width, y: 0, width: width, height: 900), width: 280, side: side)
    }

    /// One step as the app runs it: the window is told its size, then put
    /// where the width it really has belongs, and the sidebar's width is read
    /// off it.
    private func step(_ drag: EdgeDrag, _ delta: CGFloat, _ b: inout Browser, answers: Bool = true) -> CGFloat {
        if let ask = drag.ask(delta: delta) {
            if answers { b.size(ask.width) } else { b.pending = ask.width }
        }
        if let at = drag.kept(b.frame) { b.frame = at }
        return drag.width(delta: delta, beside: b.frame)
    }

    /// The pair's outer edges: the window's far edge, and the sidebar's.
    private func edges(_ side: SidebarSide, _ window: CGRect, _ width: CGFloat) -> [CGFloat] {
        side == .left ? [window.maxX, window.minX - width] : [window.minX, window.maxX + width]
    }

    @Test func draggingWiderTakesTheRoomTheWindowMakes() {
        for side in SidebarSide.allCases {
            let drag = start(side)
            var b = Browser(frame: drag.window)
            let was = edges(side, b.frame, 280)
            let asked = drag.ask(delta: 40)
            #expect(asked == CGRect(x: side == .left ? 320 : 0, y: 0, width: 960, height: 900), "\(side)")
            #expect(step(drag, 40, &b) == 320, "\(side)")
            #expect(b.frame == asked, "\(side)")
            #expect(edges(side, b.frame, 320) == was, "\(side)")
        }
    }

    @Test func draggingNarrowerGivesTheWindowTheRoom() {
        for side in SidebarSide.allCases {
            let drag = start(side)
            var b = Browser(frame: drag.window)
            let was = edges(side, b.frame, 280)
            let asked = drag.ask(delta: -40)
            #expect(asked == CGRect(x: side == .left ? 240 : 0, y: 0, width: 1040, height: 900), "\(side)")
            #expect(step(drag, -40, &b) == 240, "\(side)")
            #expect(b.frame == asked, "\(side)")
            #expect(edges(side, b.frame, 240) == was, "\(side)")
        }
    }

    /// From a review of the drag on main: a window still at the last step's
    /// width was taken for one at its minimum, and the drag stopped there.
    @Test func aWindowThatHasNotAnsweredHasNotGivenTheSpaceYet() {
        for side in SidebarSide.allCases {
            let drag = start(side)
            var b = Browser(frame: drag.window)
            let was = edges(side, b.frame, 280)
            #expect(step(drag, 40, &b) == 320, "\(side)")
            // The next step it has not answered: the sidebar has what it had.
            #expect(step(drag, 80, &b, answers: false) == 320, "\(side)")
            #expect(edges(side, b.frame, 320) == was, "\(side)")
            // The drag goes on: it is asked for where the pointer is now.
            #expect(drag.ask(delta: 120)?.width == 880, "\(side)")
            #expect(step(drag, 120, &b, answers: false) == 320, "\(side)")
            // Its answer, late: the room is the sidebar's now, the far edge where it was.
            b.answer()
            if let at = drag.kept(b.frame) { b.frame = at }
            #expect(drag.width(delta: 120, beside: b.frame) == 400, "\(side)")
            #expect(b.frame.width == 880 && edges(side, b.frame, 400) == was, "\(side)")
        }
    }

    /// From the same review: a window at its browser's minimum when the drag
    /// begins (above the 500 pt assumed: Chrome with a side panel) must not
    /// widen the sidebar, nor be moved off its tile at that width.
    @Test func aWindowAtItsMinimumGivesNoMore() {
        for side in SidebarSide.allCases {
            let drag = start(side, window: 650)
            var b = Browser(frame: drag.window)
            b.least = 650
            let at = b.frame
            for delta in [CGFloat(20), 60, 140] {
                // Asked all the same: nothing here knows its minimum.
                #expect(drag.ask(delta: delta)?.width == 650 - delta, "\(side) \(delta)")
                #expect(step(drag, delta, &b) == 280, "\(side) \(delta)")
                #expect(b.frame == at, "\(side) \(delta)")
            }
            // Back the other way it takes the room.
            #expect(step(drag, -30, &b) == 250, "\(side)")
            #expect(b.frame.width == 680 && edges(side, b.frame, 250) == edges(side, at, 280), "\(side)")
        }
    }

    @Test func aWindowThatStopsPartWayGivesThatMuch() {
        for side in SidebarSide.allCases {
            let drag = start(side, window: 700)
            var b = Browser(frame: drag.window)
            b.least = 650
            let was = edges(side, b.frame, 280)
            #expect(step(drag, 100, &b) == 330, "\(side)")
            #expect(b.frame.width == 650 && edges(side, b.frame, 330) == was, "\(side)")
        }
    }

    @Test func theSidebarKeepsToItsLimits() {
        for side in SidebarSide.allCases {
            let drag = start(side)
            var b = Browser(frame: drag.window)
            #expect(step(drag, 900, &b) == 440 && b.frame.width == 840, "\(side)")
            #expect(step(drag, -900, &b) == 200 && b.frame.width == 1080, "\(side)")
            // Read off a window narrower or wider than that, it keeps to them too.
            var odd = b.frame
            odd.size.width = 700
            #expect(drag.width(delta: 0, beside: odd) == 440, "\(side)")
            odd.size.width = 1200
            #expect(drag.width(delta: 0, beside: odd) == 200, "\(side)")
        }
        // Never asked below the 500 pt browsers are assumed to stop at; a
        // window already narrower is asked for no more.
        #expect(start(.right, window: 520).ask(delta: 100)?.width == 500)
        #expect(start(.left, window: 450).ask(delta: 100)?.width == 450)
        #expect(start(.left, window: 450).ask(delta: -50)?.width == 500)
    }

    @Test func aSidebarCoveringItsWindowChangesAlone() {
        let w = CGRect(x: 0, y: 0, width: 1440, height: 900)
        for side in SidebarSide.allCases {
            let drag = EdgeDrag(window: w, width: 280, side: side, covers: true)
            #expect(drag.ask(delta: 60) == nil && drag.kept(w.offsetBy(dx: 30, dy: 0)) == nil, "\(side)")
            #expect(drag.width(delta: 60, beside: w) == 340, "\(side)")
            #expect(drag.width(delta: 900, beside: w) == 440 && drag.width(delta: -900, beside: w) == 200, "\(side)")
        }
    }

    @Test func theLoanAtTheEndIsWhatTheWindowReallyLent() throws {
        for side in SidebarSide.allCases {
            // Snapped to the tile and narrowed by the sidebar's 280. Asked for
            // 80 more, it stops 50 on, and says so late.
            let drag = start(side)
            var b = Browser(frame: drag.window)
            _ = step(drag, 80, &b, answers: false)
            b.least = 950
            b.answer()
            if let at = drag.kept(b.frame) { b.frame = at }
            let width = drag.width(delta: 80, beside: b.frame)
            #expect(width == 330, "\(side)")
            let loan = try #require(drag.loan(lent: tile, at: b.frame), "\(side)")
            #expect(loan.phase == .lent && loan.outer == tile && loan.inner == b.frame && loan.side == side, "\(side)")
            #expect(loan.taken == width, "\(side)")
            #expect(loan.givenBack(from: b.frame, screen: tile) == tile, "\(side)")
            // With room beside it, it had lent nothing: what the drag took is lent now.
            let fresh = try #require(drag.loan(lent: nil, at: b.frame), "\(side)")
            #expect(fresh.outer == drag.window && fresh.taken == 50, "\(side)")
            // Nothing lent before and nothing given: no loan.
            #expect(drag.loan(lent: nil, at: drag.window) == nil, "\(side)")
        }
    }
}
