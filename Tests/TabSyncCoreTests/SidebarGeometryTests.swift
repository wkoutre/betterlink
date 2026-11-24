import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import TabSyncCore

struct SidebarGeometryTests {
    // A 1440x900 screen whose visible frame loses 25pt to the menu bar.
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    // A snap or move aimed at the sidebar moves the pair: the window takes the
    // rest of the rect, the sidebar keeps its width on its side.
    @Test func aRectGivenToTheSidebarIsFilledByThePair() {
        let leftHalf = CGRect(x: 0, y: 0, width: 1028, height: 1259)
        #expect(SidebarGeometry.window(filling: leftHalf, width: 280, side: .right)
                == CGRect(x: 0, y: 0, width: 748, height: 1259))
        #expect(SidebarGeometry.window(filling: leftHalf, width: 280, side: .left)
                == CGRect(x: 280, y: 0, width: 748, height: 1259))
        let full = CGRect(x: 0, y: 31, width: 2056, height: 1259)
        let w = SidebarGeometry.window(filling: full, width: 300, side: .right)
        #expect(w.maxX + 300 == full.maxX && w.minX == full.minX && w.height == full.height)
    }

    // A move that keeps the panel's width carries the pair; the browser keeps its width.
    @Test func movingThePanelWithoutResizingItMovesTheBrowserAlong() {
        let window = CGRect(x: 100, y: 100, width: 1100, height: 800)
        let panel = CGRect(x: 1175, y: 100, width: 305, height: 800) // 280 + 25 reach, on the right
        let moved = panel.offsetBy(dx: -400, dy: 50)
        #expect(SidebarGeometry.windowAfterPanelMoved(from: panel, to: moved, window: window, width: 280, side: .right,
                                                      minWindowWidth: 500) == CGRect(x: -300, y: 150, width: 1100, height: 800))
        // "Maximize height": same x and width, full height.
        let tall = CGRect(x: 1175, y: 31, width: 305, height: 1259)
        #expect(SidebarGeometry.windowAfterPanelMoved(from: panel, to: tall, window: window, width: 280, side: .right,
                                                      minWindowWidth: 500) == CGRect(x: 100, y: 31, width: 1100, height: 1259))
    }

    @Test func resizingThePanelToATileFillsItWithThePair() {
        let window = CGRect(x: 100, y: 100, width: 1100, height: 800)
        let panel = CGRect(x: 1175, y: 100, width: 305, height: 800)
        let leftHalf = CGRect(x: 0, y: 31, width: 1028, height: 1259)
        #expect(SidebarGeometry.windowAfterPanelMoved(from: panel, to: leftHalf, window: window, width: 280, side: .right,
                                                      minWindowWidth: 500) == CGRect(x: 0, y: 31, width: 748, height: 1259))
    }

    @Test func aRectTooNarrowForTheBrowserOverflowsAwayFromTheSidebar() {
        let quarter = CGRect(x: 1542, y: 0, width: 514, height: 1259)
        // Sidebar on the right stays at the rect's right edge; the window keeps its minimum.
        let w = SidebarGeometry.window(filling: quarter, width: 280, side: .right, minWindowWidth: 626)
        #expect(w.width == 626 && w.maxX == quarter.maxX - 280)
        let l = SidebarGeometry.window(filling: quarter, width: 280, side: .left, minWindowWidth: 626)
        #expect(l.width == 626 && l.minX == quarter.minX + 280)
    }

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

    /// Review F1: a narrowed window can land on a snap line itself (0..688 is
    /// on the one-third line of 2056), so geometry alone would narrow it again.
    /// FitMemory remembers it by its window number, across launches.
    @Test func aNarrowedWindowIsRememberedNotNarrowedAgain() throws {
        let big = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        let half = CGRect(x: 0, y: 0, width: 1028, height: 1259)
        let inner = try #require(SidebarGeometry.settled(window: half, screen: big, width: 340, side: .right))
        #expect(inner == CGRect(x: 0, y: 0, width: 688, height: 1259))
        #expect(SidebarGeometry.isSnapped(inner, screen: big)) // why geometry alone can't tell
        var memory = FitMemory()
        memory.record(.init(bundleId: "com.google.Chrome", window: 41, inner: inner, outer: half))
        let saved = try JSONDecoder().decode(FitMemory.self, from: JSONEncoder().encode(memory)) // a relaunch
        #expect(saved.fitted(CGRect(x: 0.5, y: 0, width: 688, height: 1259), window: 41)?.outer == half)
        #expect(saved.fitted(half, window: 41) == nil) // moved since
    }

    /// Review round 3, N2: another window of the same browser, snapped to the
    /// frame some window was narrowed to, is a fresh snap, not a fitted window.
    @Test func anotherWindowAtARememberedFrameIsNotMistakenForIt() {
        var memory = FitMemory()
        let inner = CGRect(x: 0, y: 0, width: 1080, height: 875), full = CGRect(x: 0, y: 0, width: 1440, height: 875)
        memory.record(.init(bundleId: "com.google.Chrome", window: 41, inner: inner, outer: full))
        #expect(memory.fitted(inner, window: 42) == nil)
        #expect(SidebarGeometry.settled(window: inner, screen: full, width: 360, side: .right) == CGRect(x: 0, y: 0, width: 720, height: 875))
    }

    @Test func recordsOfClosedWindowsArePruned() {
        var memory = FitMemory()
        let r = CGRect(x: 0, y: 0, width: 700, height: 800)
        memory.record(.init(bundleId: "a", window: 1, inner: r, outer: r))
        memory.record(.init(bundleId: "a", window: 2, inner: r, outer: r))
        memory.prune(alive: [2, 9])
        #expect(memory.entries.map(\.window) == [2])
        memory.forget(window: 2)
        #expect(memory.entries.isEmpty)
    }

    /// Review round 2, N2: a window the user has just snapped is always narrowed,
    /// even when it plus the sidebar would land on another snap line.
    @Test func aFreshlySnappedWindowIsAlwaysNarrowed() {
        for (sw, w) in [(1440.0, 360.0), (1440, 240), (1920, 320), (1728, 290), (2056, 340)] {
            let scr = CGRect(x: 0, y: 0, width: sw, height: 875)
            for tile in [CGRect(x: 0, y: 0, width: sw / 2, height: 875), CGRect(x: 0, y: 0, width: sw / 3, height: 875), scr] {
                #expect(SidebarGeometry.settled(window: tile, screen: scr, width: w, side: .right) != nil, "\(sw) \(w) \(tile)")
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
