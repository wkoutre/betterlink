import CoreGraphics
import Testing
@testable import TabSyncCore

struct SidebarSlideTests {
    /// The sidebar's inner edge opens from its outer edge by its width.
    @Test func theInnerEdgeOpensFromTheOuterEdge() {
        for p in stride(from: 0.0, through: 1.0, by: 0.125) {
            #expect(SidebarSlide.innerEdge(outerEdge: 1028, width: 280, side: .right, progress: p) == 1028 - 280 * CGFloat(p))
            #expect(SidebarSlide.innerEdge(outerEdge: 1028, width: 280, side: .left, progress: p) == 1028 + 280 * CGFloat(p))
        }
        #expect(SidebarSlide.innerEdge(outerEdge: 0, width: 280, side: .left, progress: 2) == 280)
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
