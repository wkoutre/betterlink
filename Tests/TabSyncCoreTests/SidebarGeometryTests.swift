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
        let p = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .right)
        #expect(p.sidebar == CGRect(x: 1000, y: 50, width: 280, height: 700))
        #expect(!p.overlaps)
    }

    @Test func sitsFlushOutsideTheLeftEdgeWhenThereIsRoom() {
        let win = CGRect(x: 400, y: 50, width: 900, height: 700)
        let p = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .left)
        #expect(p.sidebar == CGRect(x: 120, y: 50, width: 280, height: 700))
        #expect(p.side == .left)
    }

    @Test func autoPicksTheSideWithMoreRoomAndRightOnATie() {
        let leftHeavy = CGRect(x: 500, y: 0, width: 800, height: 875)
        #expect(SidebarGeometry.place(window: leftHeavy, screen: screen, width: 200, side: .auto).side == .left)
        let centred = CGRect(x: 320, y: 0, width: 800, height: 875)
        #expect(SidebarGeometry.place(window: centred, screen: screen, width: 200, side: .auto).side == .right)
    }

    private func settle(_ w: CGRect, _ side: SidebarSide) -> CGRect? {
        SidebarGeometry.settled(window: w, screen: screen, width: 280, side: side)
    }

    /// Every tile x every side: the window and its sidebar fill exactly the tile.
    @Test func aSnappedWindowAndItsSidebarFillExactlyTheTile() throws {
        let h = screen.height, sw = screen.width
        let tiles = [
            screen,
            CGRect(x: 0, y: 0, width: sw / 2, height: h), CGRect(x: sw / 2, y: 0, width: sw / 2, height: h),
            CGRect(x: 0, y: 0, width: sw * 2 / 3, height: h), CGRect(x: sw / 3, y: 0, width: sw * 2 / 3, height: h),
            CGRect(x: sw / 4, y: 0, width: sw * 3 / 4, height: h),
            CGRect(x: sw / 4, y: 0, width: sw / 2, height: h),
        ]
        for tile in tiles {
            for side in [SidebarSide.left, .right] {
                let win = try #require(SidebarGeometry.settled(window: tile, screen: screen, width: 200, side: side))
                let sb = SidebarGeometry.place(window: win, screen: screen, width: 200, side: side).sidebar
                #expect(win.union(sb) == tile, "\(tile) \(side)")
                #expect(win.width + sb.width == tile.width, "\(tile) \(side)")
            }
        }
    }

    @Test func quarterTilesAndWindowManagerGapsCountAsSnapped() {
        #expect(SidebarGeometry.isSnapped(CGRect(x: 720, y: 437, width: 720, height: 438), screen: screen))
        #expect(SidebarGeometry.isSnapped(CGRect(x: 8, y: 8, width: 708, height: 859), screen: screen))
        #expect(!SidebarGeometry.isSnapped(CGRect(x: 100, y: 50, width: 900, height: 700), screen: screen))
        // Snapped left and right but placed by hand vertically.
        #expect(!SidebarGeometry.isSnapped(CGRect(x: 0, y: 60, width: 720, height: 700), screen: screen))
    }

    @Test func aWindowPlacedByHandGivesUpOnlyWhatIsMissing() {
        // 100pt free on the right, sidebar needs 280: the window gives up 180.
        #expect(settle(CGRect(x: 40, y: 60, width: 1300, height: 700), .right)
            == CGRect(x: 40, y: 60, width: 1120, height: 700))
        #expect(settle(CGRect(x: 100, y: 60, width: 1300, height: 700), .left)
            == CGRect(x: 280, y: 60, width: 1120, height: 700))
        #expect(settle(CGRect(x: 100, y: 60, width: 900, height: 700), .right) == nil)
    }

    @Test func aWindowDraggedPastTheScreenEdgeIsLeftAlone() {
        #expect(settle(CGRect(x: 800, y: 60, width: 900, height: 700), .right) == nil)
        #expect(settle(CGRect(x: -300, y: 60, width: 900, height: 700), .left) == nil)
    }

    /// The live case: Chrome stops at 626pt, so a third or quarter tile can't hold the pair.
    @Test func atTheBrowsersMinimumWidthThePairStaysOnScreen() {
        let big = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        for tile in [CGRect(x: 1371, y: 0, width: 685, height: 1259), CGRect(x: 1542, y: 0, width: 514, height: 1259),
                     CGRect(x: 0, y: 0, width: 685, height: 1259), CGRect(x: 0, y: 0, width: 514, height: 1259)] {
            for side in SidebarSide.allCases {
                let win = SidebarGeometry.settled(window: tile, screen: big, width: 280, side: side, minWindowWidth: 626) ?? tile
                let used = SidebarGeometry.resolve(side, window: tile, screen: big)
                let pair = win.union(SidebarGeometry.place(window: win, screen: big, width: 280, side: used).sidebar)
                #expect(win.width == 626, "\(tile) \(side)")
                #expect(pair.minX >= big.minX && pair.maxX <= big.maxX && pair.width == 906, "\(tile) \(side) \(pair)")
            }
        }
    }

    @Test func whenTheBrowserRefusesTheSidebarCoversTheEdgeInstead() {
        let p = SidebarGeometry.place(window: screen, screen: screen, width: 280, side: .right, keepOnScreen: true)
        #expect(p.overlaps)
        #expect(p.sidebar == CGRect(x: 1160, y: 0, width: 280, height: 875))
    }

    @Test func whileDraggedOffScreenTheSidebarStaysAttached() {
        let p = SidebarGeometry.place(window: CGRect(x: 900, y: 60, width: 540, height: 700), screen: screen, width: 280, side: .right)
        #expect(p.sidebar.minX == 1440)
        #expect(!p.overlaps)
    }

    @Test func neverRunsUnderTheMenuBarOrBelowTheScreen() {
        let tall = CGRect(x: 100, y: -40, width: 800, height: 1000)
        let p = SidebarGeometry.place(window: tall, screen: screen, width: 280, side: .right)
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
