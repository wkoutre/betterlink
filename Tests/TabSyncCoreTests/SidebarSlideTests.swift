import CoreGraphics
import Testing
@testable import TabSyncCore

struct SidebarSlideTests {
    // Chrome snapped to the left half (0...1028); sidebar 280 on the right.
    let tile = CGRect(x: 0, y: 0, width: 1028, height: 1259)
    var shownRight: CGRect { CGRect(x: 0, y: 0, width: 748, height: 1259) }

    @Test func theSeamIsTheComplementOnTheRight() {
        for p in stride(from: 0.0, through: 1.0, by: 0.125) {
            let f = SidebarSlide.frames(hiddenWindow: tile, shownWindow: shownRight, outerEdge: 1028, width: 280, side: .right, progress: p)
            #expect(f.window.maxX == f.innerEdge)              // no gap, no overlap
            #expect(f.window.minX == 0 && f.window.height == 1259)
            #expect(abs((1028 - f.innerEdge) - 280 * CGFloat(p)) < 1e-9) // sidebar width grows with p
        }
        #expect(SidebarSlide.frames(hiddenWindow: tile, shownWindow: shownRight, outerEdge: 1028, width: 280, side: .right, progress: 0).window == tile)
        #expect(SidebarSlide.frames(hiddenWindow: tile, shownWindow: shownRight, outerEdge: 1028, width: 280, side: .right, progress: 1).window == shownRight)
    }

    @Test func theSeamIsTheComplementOnTheLeft() {
        let right = CGRect(x: 1028, y: 0, width: 1028, height: 1259)  // snapped to the right half
        let shown = CGRect(x: 1308, y: 0, width: 748, height: 1259)
        for p in stride(from: 0.0, through: 1.0, by: 0.125) {
            let f = SidebarSlide.frames(hiddenWindow: right, shownWindow: shown, outerEdge: 1028, width: 280, side: .left, progress: p)
            #expect(f.window.minX == f.innerEdge)
            #expect(f.window.maxX == 2056)                     // the window's far edge stays put
        }
    }

    /// A window narrowed only to the least the sidebar asks of a browser
    /// (500 pt) can't keep its far edge: the pair shifts to fit. The slide ends
    /// exactly on that frame, never narrower than it, the seam tight all along.
    @Test func aShiftedPairEndsOnTheShownFrame() {
        let half = CGRect(x: 0, y: 0, width: 748, height: 859)
        let shownLeft = CGRect(x: 280, y: 0, width: 500, height: 859)
        let shownRight = CGRect(x: 716, y: 0, width: 500, height: 859)
        let rightHalf = CGRect(x: 748, y: 0, width: 748, height: 859)
        for p in stride(from: 0.0, through: 1.0, by: 0.125) {
            let l = SidebarSlide.frames(hiddenWindow: half, shownWindow: shownLeft, outerEdge: 0, width: 280, side: .left, progress: p)
            #expect(l.window.minX == l.innerEdge && l.window.width >= 500)
            let r = SidebarSlide.frames(hiddenWindow: rightHalf, shownWindow: shownRight, outerEdge: 1496, width: 280, side: .right, progress: p)
            #expect(r.window.maxX == r.innerEdge && r.window.width >= 500)
        }
        #expect(SidebarSlide.frames(hiddenWindow: half, shownWindow: shownLeft, outerEdge: 0, width: 280, side: .left, progress: 1).window == shownLeft)
        #expect(SidebarSlide.frames(hiddenWindow: rightHalf, shownWindow: shownRight, outerEdge: 1496, width: 280, side: .right, progress: 1).window == shownRight)
        #expect(SidebarSlide.frames(hiddenWindow: half, shownWindow: shownLeft, outerEdge: 0, width: 280, side: .left, progress: 0).window == half)
    }

    @Test func aWindowWithoutRoomStaysWhileTheSidebarOpens() {
        let free = CGRect(x: 200, y: 100, width: 800, height: 700)
        let f = SidebarSlide.frames(hiddenWindow: free, shownWindow: free, outerEdge: 1280, width: 280, side: .right, progress: 0.5)
        #expect(f.window == free && f.innerEdge == 1140)
    }

    @Test func aSlideEasesFromZeroToOne() {
        var s = SidebarSlide(shown: false)
        s.show(at: 0, reduceMotion: false)
        #expect(s.progress(at: 0) == 0)
        #expect(s.progress(at: SidebarSlide.duration / 2) == 0.5)
        #expect(s.progress(at: SidebarSlide.duration) == 1)
        s.settle(at: SidebarSlide.duration)
        #expect(s.phase == .shown)
    }

    @Test func interruptingTurnsBackFromWhereItIs() {
        var s = SidebarSlide(shown: true)
        s.hide(at: 0, reduceMotion: false)
        let t = SidebarSlide.duration * 0.3
        let here = s.progress(at: t)
        s.show(at: t, reduceMotion: false)
        #expect(s.phase == .showing)
        #expect(abs(s.progress(at: t) - here) < 1e-9)          // no jump
        #expect(s.progress(at: t + SidebarSlide.duration) == 1)
    }

    @Test func reduceMotionIsImmediate() {
        var s = SidebarSlide(shown: true)
        s.hide(at: 0, reduceMotion: true)
        #expect(s.phase == .hidden && s.progress(at: 0) == 0)
    }

    /// The sidebar's revealed edge is the window's real edge: a browser slow to
    /// resize is waited for, never run ahead of, showing or hiding.
    @Test func theSeamWaitsForASlowBrowser() {
        // Left: the window's edge goes 0...280. Right: 1028...748.
        #expect(SidebarSlide.seam(windowEdge: 280, innerEdge: 100, hiddenEdge: 0, side: .left) == 280)   // hiding, not widened yet
        #expect(SidebarSlide.seam(windowEdge: 0, innerEdge: 150, hiddenEdge: 0, side: .left) == 0)       // showing, not narrowed yet
        #expect(SidebarSlide.seam(windowEdge: 748, innerEdge: 900, hiddenEdge: 1028, side: .right) == 748)
        #expect(SidebarSlide.seam(windowEdge: 1028, innerEdge: 880, hiddenEdge: 1028, side: .right) == 1028)
        #expect(SidebarSlide.seam(windowEdge: 140, innerEdge: 140, hiddenEdge: 0, side: .left) == 140)   // in step
    }

    /// A window that lent less than the sidebar's width stops at its full
    /// width; past that edge the sidebar goes on alone.
    @Test func pastTheWindowsFullWidthTheSidebarGoesOnAlone() {
        #expect(SidebarSlide.seam(windowEdge: 100, innerEdge: 40, hiddenEdge: 100, side: .left) == 40)
        #expect(SidebarSlide.seam(windowEdge: 928, innerEdge: 990, hiddenEdge: 928, side: .right) == 990)
        // Not there yet: the sidebar still waits for it.
        #expect(SidebarSlide.seam(windowEdge: 180, innerEdge: 40, hiddenEdge: 100, side: .left) == 180)
        #expect(SidebarSlide.seam(windowEdge: 860, innerEdge: 990, hiddenEdge: 928, side: .right) == 860)
    }
}
