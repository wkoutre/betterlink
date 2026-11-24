import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import TabSyncCore

struct SidebarGeometryTests {
    // A 1440x900 screen whose visible frame loses 25pt to the menu bar.
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func sitsFlushOutsideTheRightEdgeWhenThereIsRoom() {
        let win = CGRect(x: 100, y: 50, width: 900, height: 700)
        let p = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .right, makeRoom: false)
        #expect(p.sidebar == CGRect(x: 1000, y: 50, width: 280, height: 700))
        #expect(p.window == nil)
        #expect(!p.overlaps)
    }

    @Test func sitsFlushOutsideTheLeftEdgeWhenThereIsRoom() {
        let win = CGRect(x: 400, y: 50, width: 900, height: 700)
        let p = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .left, makeRoom: false)
        #expect(p.sidebar == CGRect(x: 120, y: 50, width: 280, height: 700))
        #expect(p.side == .left)
    }

    @Test func autoPicksTheSideWithMoreRoomAndRightOnATie() {
        let leftHeavy = CGRect(x: 500, y: 0, width: 800, height: 875)
        #expect(SidebarGeometry.place(window: leftHeavy, screen: screen, width: 200, side: .auto, makeRoom: false).side == .left)
        let centred = CGRect(x: 320, y: 0, width: 800, height: 875)
        #expect(SidebarGeometry.place(window: centred, screen: screen, width: 200, side: .auto, makeRoom: false).side == .right)
    }

    @Test func makeRoomNarrowsAMaximisedWindowSoThePairFillsTheScreen() {
        let full = screen
        let right = SidebarGeometry.place(window: full, screen: screen, width: 280, side: .right, makeRoom: true)
        #expect(right.window == CGRect(x: 0, y: 0, width: 1160, height: 875))
        #expect(right.sidebar == CGRect(x: 1160, y: 0, width: 280, height: 875))

        let left = SidebarGeometry.place(window: full, screen: screen, width: 280, side: .left, makeRoom: true)
        #expect(left.window == CGRect(x: 280, y: 0, width: 1160, height: 875))
        #expect(left.sidebar == CGRect(x: 0, y: 0, width: 280, height: 875))
    }

    @Test func makeRoomOnlyTakesWhatIsMissing() {
        // 100pt free on the right, sidebar needs 280: the window gives up 180.
        let win = CGRect(x: 0, y: 0, width: 1340, height: 875)
        let p = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .right, makeRoom: true)
        #expect(p.window?.width == 1160)
        #expect(p.sidebar.minX == 1160)
        #expect(p.sidebar.maxX == screen.maxX)
    }

    @Test func onceRoomIsMadeTheNextPassLeavesTheWindowAlone() {
        let made = SidebarGeometry.place(window: screen, screen: screen, width: 280, side: .right, makeRoom: true)
        let again = SidebarGeometry.place(window: made.window!, screen: screen, width: 280, side: .right, makeRoom: true)
        #expect(again.window == nil)
        #expect(again.sidebar == made.sidebar)
    }

    @Test func withoutMakeRoomAFullWindowGetsTheSidebarOverItsEdge() {
        let p = SidebarGeometry.place(window: screen, screen: screen, width: 280, side: .right, makeRoom: false)
        #expect(p.overlaps)
        #expect(p.sidebar == CGRect(x: 1160, y: 0, width: 280, height: 875))
    }

    @Test func neverRunsUnderTheMenuBarOrBelowTheScreen() {
        let tall = CGRect(x: 100, y: -40, width: 800, height: 1000)
        let p = SidebarGeometry.place(window: tall, screen: screen, width: 280, side: .right, makeRoom: false)
        #expect(p.sidebar.minY == 0)
        #expect(p.sidebar.maxY == 875)
    }

    @Test func axAndCocoaFramesRoundTrip() {
        // AX: 100pt from the top of a 900pt main screen, 700 tall.
        let ax = CGRect(x: 100, y: 100, width: 900, height: 700)
        let c = SidebarGeometry.cocoa(fromAX: ax, mainScreenHeight: 900)
        #expect(c == CGRect(x: 100, y: 100, width: 900, height: 700))
        let ax2 = CGRect(x: 0, y: 25, width: 500, height: 400)
        let c2 = SidebarGeometry.cocoa(fromAX: ax2, mainScreenHeight: 900)
        #expect(c2.maxY == 875)
        #expect(SidebarGeometry.ax(fromCocoa: c2, mainScreenHeight: 900) == ax2)
    }
}
