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
        #expect(SidebarGeometry.windowAfterPanelMoved(from: panel, to: moved, window: window, width: 280, side: .right)
                == CGRect(x: -300, y: 150, width: 1100, height: 800))
        // "Maximize height": same x and width, full height.
        let tall = CGRect(x: 1175, y: 31, width: 305, height: 1259)
        #expect(SidebarGeometry.windowAfterPanelMoved(from: panel, to: tall, window: window, width: 280, side: .right)
                == CGRect(x: 100, y: 31, width: 1100, height: 1259))
    }

    @Test func resizingThePanelToATileFillsItWithThePair() {
        let window = CGRect(x: 100, y: 100, width: 1100, height: 800)
        let panel = CGRect(x: 1175, y: 100, width: 305, height: 800)
        let leftHalf = CGRect(x: 0, y: 31, width: 1028, height: 1259)
        #expect(SidebarGeometry.windowAfterPanelMoved(from: panel, to: leftHalf, window: window, width: 280, side: .right)
                == CGRect(x: 0, y: 31, width: 748, height: 1259))
    }

    @Test func sitsFlushOutsideTheRightEdge() {
        let win = CGRect(x: 100, y: 50, width: 900, height: 700)
        let p = SidebarGeometry.place(window: win, width: 280, side: .right)
        #expect(p.sidebar == CGRect(x: 1000, y: 50, width: 280, height: 700))
    }

    @Test func sitsFlushOutsideTheLeftEdge() {
        let win = CGRect(x: 400, y: 50, width: 900, height: 700)
        let p = SidebarGeometry.place(window: win, width: 280, side: .left)
        #expect(p.sidebar == CGRect(x: 120, y: 50, width: 280, height: 700))
        #expect(p.side == .left)
    }

    @Test func draggingTheEdgeBetweenThemKeepsThePairsOuterEdges() {
        let win = CGRect(x: 280, y: 0, width: 900, height: 700)
        let right = SidebarGeometry.resized(window: win, width: 280, to: 320, side: .right)
        #expect(right.width == 320 && right.window == CGRect(x: 280, y: 0, width: 860, height: 700))
        let left = SidebarGeometry.resized(window: win, width: 280, to: 320, side: .left)
        #expect(left.width == 320 && left.window == CGRect(x: 320, y: 0, width: 860, height: 700))
        let narrower = SidebarGeometry.resized(window: win, width: 280, to: 240, side: .left)
        #expect(narrower.width == 240 && narrower.window == CGRect(x: 240, y: 0, width: 940, height: 700))
    }

    /// The sidebar's own limits; the browser is asked for whatever is left,
    /// and what it really takes is read off its window.
    @Test func draggingTheEdgeStopsAtTheSidebarsLimits() {
        func width(_ wanted: CGFloat, window w: CGFloat) -> CGFloat {
            SidebarGeometry.resized(window: CGRect(x: 280, y: 0, width: w, height: 700), width: 280, to: wanted, side: .right).width
        }
        #expect(width(50, window: 900) == 200)
        #expect(width(900, window: 900) == 440)
        #expect(width(440, window: 100) == 379) // the browser is asked down to a point
    }

    /// Rule 2: open, the sidebar and the browser share the window's frame,
    /// the browser's far edge where it was: wherever the window is, any width.
    @Test func openedThePairFillsTheWindowsFrame() {
        for frame in [screen, CGRect(x: 300, y: 80, width: 700, height: 500), CGRect(x: -200, y: 0, width: 900, height: 875),
                      CGRect(x: 1200, y: 0, width: 600, height: 875)] {
            for side in SidebarSide.allCases {
                for width in [CGFloat(200), 280, 440] {
                    let b = SidebarGeometry.opened(frame, width: width, side: side)
                    let sb = SidebarGeometry.place(window: b, width: width, side: side).sidebar
                    #expect(b.union(sb) == frame && b.width + sb.width == frame.width, "\(frame) \(side) \(width)")
                    #expect(side == .left ? b.maxX == frame.maxX : b.minX == frame.minX, "\(frame) \(side) \(width)")
                }
            }
        }
        // Narrower than the sidebar: the browser is asked for a point, and has what it takes.
        #expect(SidebarGeometry.opened(CGRect(x: 0, y: 0, width: 150, height: 400), width: 280, side: .left).width == 1)
    }

    /// Rule 4: closed, the browser takes the pair's frame, on screen.
    @Test func closedTheBrowserTakesThePairsFrame() {
        let display = [CGRect(x: 0, y: 0, width: 1440, height: 900)]
        let b = CGRect(x: 400, y: 50, width: 700, height: 700)
        #expect(SidebarGeometry.closed(browser: b, width: 280, side: .left, displays: display) == CGRect(x: 120, y: 50, width: 980, height: 700))
        #expect(SidebarGeometry.closed(browser: b, width: 280, side: .right, displays: display) == CGRect(x: 400, y: 50, width: 980, height: 700))
        // The sidebar was off the display's edge: the browser, at the pair's width, on it.
        let atLeft = CGRect(x: 100, y: 0, width: 700, height: 700)
        #expect(SidebarGeometry.closed(browser: atLeft, width: 280, side: .left, displays: display) == CGRect(x: 0, y: 0, width: 980, height: 700))
        let atRight = CGRect(x: 900, y: 0, width: 500, height: 700)
        #expect(SidebarGeometry.closed(browser: atRight, width: 280, side: .right, displays: display) == CGRect(x: 660, y: 0, width: 780, height: 700))
        // A second display beside it at that height counts as screen.
        let two = display + [CGRect(x: 1440, y: -100, width: 1920, height: 1080)]
        #expect(SidebarGeometry.closed(browser: atRight, width: 280, side: .right, displays: two) == CGRect(x: 900, y: 0, width: 780, height: 700))
        // Wider than the displays (widened while open): it fills them.
        #expect(SidebarGeometry.closed(browser: CGRect(x: 300, y: 0, width: 1300, height: 700), width: 280, side: .left, displays: display)
                == CGRect(x: 0, y: 0, width: 1440, height: 700))
        // Opening and closing in the same place gives the frame back.
        for side in SidebarSide.allCases {
            let f = CGRect(x: 0, y: 0, width: 1440, height: 875)
            #expect(SidebarGeometry.closed(browser: SidebarGeometry.opened(f, width: 280, side: side), width: 280, side: side, displays: display) == f)
        }
    }

    /// A saved "auto" (removed) reads as no side, so the default is used.
    @Test func autoIsNoLongerASide() { #expect(SidebarSide(rawValue: "auto") == nil) }

    /// A window whose sidebar is open is remembered by its window number,
    /// across launches: from its frame alone it can't be told from one that
    /// is not narrowed, and it is not narrowed again.
    @Test func anOpenWindowIsRememberedNotNarrowedAgain() throws {
        let half = CGRect(x: 0, y: 0, width: 1028, height: 1259)
        let inner = SidebarGeometry.opened(half, width: 340, side: .right)
        #expect(inner == CGRect(x: 0, y: 0, width: 688, height: 1259))
        var memory = FitMemory()
        memory.record(.init(bundleId: "com.google.Chrome", window: 41, inner: inner, outer: half))
        let saved = try JSONDecoder().decode(FitMemory.self, from: JSONEncoder().encode(memory)) // a relaunch
        #expect(saved.fitted(CGRect(x: 0.5, y: 0, width: 688, height: 1259), window: 41)?.outer == half)
        #expect(saved.fitted(half, window: 41) == nil) // moved since
    }

    /// Another window of the same browser, at the frame some window is
    /// remembered at, is not mistaken for it.
    @Test func anotherWindowAtARememberedFrameIsNotMistakenForIt() {
        var memory = FitMemory()
        let inner = CGRect(x: 0, y: 0, width: 1080, height: 875), full = CGRect(x: 0, y: 0, width: 1440, height: 875)
        memory.record(.init(bundleId: "com.google.Chrome", window: 41, inner: inner, outer: full))
        #expect(memory.fitted(inner, window: 42) == nil)
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

    @Test func whileDraggedOffScreenTheSidebarStaysAttached() {
        let p = SidebarGeometry.place(window: CGRect(x: 900, y: 60, width: 540, height: 700), width: 280, side: .right)
        #expect(p.sidebar.minX == 1440)
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

    /// A person's resize of the open pair at rest refits it only when the
    /// sidebar beside the new frame would be further outside the screens'
    /// visible frames than it was (bug 3: Window › Fill, a zoom, tiling to
    /// the whole screen). Any other resize is the person's and stands (rule
    /// 3, review F1 of 1df43a3: a left edge dragged from 400 to 300 beside a
    /// 280 pt left sidebar was put back to 580).
    @Test func aResizeRefitsOnlyWhenTheSidebarWouldLeaveTheScreen() {
        let visible = [CGRect(x: 0, y: 0, width: 2056, height: 1259)]
        let pairLeft = CGRect(x: 400, y: 0, width: 1200, height: 1259) // sidebar 120...400
        // The left edge dragged over where the sidebar was: theirs.
        #expect(!SidebarGeometry.refitsAfterResize(from: pairLeft, to: CGRect(x: 300, y: 0, width: 1300, height: 1259), width: 280, side: .left,
                                                   visible: visible))
        // Narrowed, widened to the right, taller: theirs.
        #expect(!SidebarGeometry.refitsAfterResize(from: pairLeft, to: CGRect(x: 450, y: 0, width: 1100, height: 1259), width: 280, side: .left,
                                                   visible: visible))
        #expect(!SidebarGeometry.refitsAfterResize(from: pairLeft, to: CGRect(x: 400, y: 0, width: 1500, height: 1259), width: 280, side: .left,
                                                   visible: visible))
        // Filled: the sidebar would be at -280...0.
        #expect(SidebarGeometry.refitsAfterResize(from: pairLeft, to: visible[0], width: 280, side: .left, visible: visible))
        // From a pair filling the screen too.
        #expect(SidebarGeometry.refitsAfterResize(from: CGRect(x: 280, y: 0, width: 1776, height: 1259), to: visible[0], width: 280, side: .left,
                                                  visible: visible))
        // The right side: its right edge dragged past where the sidebar was, still on screen: theirs; filled: refit.
        let pairRight = CGRect(x: 400, y: 0, width: 1200, height: 1259) // sidebar 1600...1880
        #expect(!SidebarGeometry.refitsAfterResize(from: pairRight, to: CGRect(x: 400, y: 0, width: 1300, height: 1259), width: 280, side: .right,
                                                   visible: visible))
        #expect(SidebarGeometry.refitsAfterResize(from: pairRight, to: visible[0], width: 280, side: .right, visible: visible))
        // A pair already partly off the screen, resized without pushing the sidebar further off: theirs.
        let off = CGRect(x: 100, y: 0, width: 1200, height: 1259) // sidebar -180...100
        #expect(!SidebarGeometry.refitsAfterResize(from: off, to: CGRect(x: 150, y: 0, width: 1100, height: 1259), width: 280, side: .left,
                                                   visible: visible))
        // A move alone (the same size) stands, wherever it puts the sidebar.
        #expect(!SidebarGeometry.refitsAfterResize(from: pairLeft, to: pairLeft.offsetBy(dx: -400, dy: 0), width: 280, side: .left,
                                                   visible: visible))
        // Onto a second display beside: the sidebar on that display is on screen.
        let two = [CGRect(x: -1440, y: 0, width: 1440, height: 900), visible[0]]
        #expect(!SidebarGeometry.refitsAfterResize(from: pairLeft, to: CGRect(x: 0, y: 0, width: 1600, height: 800), width: 280, side: .left,
                                                   visible: two))
    }

    /// A drag of one of the browser's horizontal edges, or of a corner, is
    /// the person's and stands even when it takes the sidebar beside it off
    /// the screen (rule 3: nothing puts them back). Only a placement, both
    /// horizontal edges moved (Fill, a zoom, tiling to a half or a quarter),
    /// or the window across a display's whole visible width, refits the pair.
    @Test func aDragOfOneEdgeStandsAndAPlacementRefits() {
        let visible = [CGRect(x: 0, y: 0, width: 2056, height: 1259)]
        let right = CGRect(x: 0, y: 0, width: 1776, height: 1259) // sidebar 1776...2056
        let left = CGRect(x: 280, y: 0, width: 1776, height: 1259) // sidebar 0...280
        // The sidebar-side edge dragged 100 past where the screen ends for the sidebar: stands.
        #expect(!SidebarGeometry.refitsAfterResize(from: right, to: CGRect(x: 0, y: 0, width: 1876, height: 1259), width: 280, side: .right,
                                                   visible: visible))
        #expect(!SidebarGeometry.refitsAfterResize(from: left, to: CGRect(x: 180, y: 0, width: 1876, height: 1259), width: 280, side: .left,
                                                   visible: visible))
        // A corner: one horizontal edge and a vertical one: stands.
        #expect(!SidebarGeometry.refitsAfterResize(from: right, to: CGRect(x: 0, y: 200, width: 1876, height: 1059), width: 280, side: .right,
                                                   visible: visible))
        #expect(!SidebarGeometry.refitsAfterResize(from: left, to: CGRect(x: 180, y: 0, width: 1876, height: 1059), width: 280, side: .left,
                                                   visible: visible))
        // The far edge alone, whatever the sidebar: stands.
        #expect(!SidebarGeometry.refitsAfterResize(from: left, to: CGRect(x: 280, y: 0, width: 1500, height: 1259), width: 280, side: .left,
                                                   visible: visible))
        // Tiled to the left half, or the top left quarter, with the sidebar on the left: both edges moved, refit.
        #expect(SidebarGeometry.refitsAfterResize(from: left, to: CGRect(x: 0, y: 0, width: 1028, height: 1259), width: 280, side: .left,
                                                  visible: visible))
        #expect(SidebarGeometry.refitsAfterResize(from: left, to: CGRect(x: 0, y: 630, width: 1028, height: 629), width: 280, side: .left,
                                                  visible: visible))
        // Tiled to the right half with the sidebar on the right: refit.
        #expect(SidebarGeometry.refitsAfterResize(from: right, to: CGRect(x: 1028, y: 0, width: 1028, height: 1259), width: 280, side: .right,
                                                  visible: visible))
        // Both edges moved but the sidebar still on the screen: stands.
        #expect(!SidebarGeometry.refitsAfterResize(from: CGRect(x: 600, y: 0, width: 800, height: 1259), to: CGRect(x: 500, y: 0, width: 1100, height: 1259),
                                                   width: 280, side: .left, visible: visible))
        // Filled from a pair that filled the screen already: one edge moves, but the window spans the whole visible width.
        #expect(SidebarGeometry.refitsAfterResize(from: right, to: visible[0], width: 280, side: .right, visible: visible))
        #expect(SidebarGeometry.refitsAfterResize(from: left, to: visible[0], width: 280, side: .left, visible: visible))
        // A move alone stands, wherever it puts the sidebar.
        #expect(!SidebarGeometry.refitsAfterResize(from: right, to: right.offsetBy(dx: 300, dy: 0), width: 280, side: .right, visible: visible))
    }

    /// A pair that fills the screen's width, tiled to the top or bottom half
    /// (Window › Move & Resize; review round 3 of PR 105, F2): only the
    /// browser's edge on the sidebar's side moves, and the tile isn't the
    /// whole visible frame, but the browser now spans the display's whole
    /// visible width. That is a placement: the pair fits again. Either side.
    @Test func aFullWidthPairTiledToATopOrBottomHalfRefits() {
        let visible = [CGRect(x: 0, y: 0, width: 2056, height: 1259)]
        let right = CGRect(x: 0, y: 0, width: 1776, height: 1259) // sidebar 1776...2056
        let left = CGRect(x: 280, y: 0, width: 1776, height: 1259) // sidebar 0...280
        for half in [CGRect(x: 0, y: 630, width: 2056, height: 629), CGRect(x: 0, y: 0, width: 2056, height: 630)] {
            #expect(SidebarGeometry.refitsAfterResize(from: right, to: half, width: 280, side: .right, visible: visible), "right, to \(half)")
            #expect(SidebarGeometry.refitsAfterResize(from: left, to: half, width: 280, side: .left, visible: visible), "left, to \(half)")
        }
        // On the second of two displays side by side: its whole visible width.
        let two = [CGRect(x: -1440, y: 0, width: 1440, height: 875), visible[0]]
        #expect(SidebarGeometry.refitsAfterResize(from: right, to: CGRect(x: 0, y: 630, width: 2056, height: 629), width: 280, side: .right, visible: two))
        // The sidebar-side edge dragged to 3 pt short of the full width: a drag of one edge, which stands.
        #expect(!SidebarGeometry.refitsAfterResize(from: right, to: CGRect(x: 0, y: 0, width: 2053, height: 1259), width: 280, side: .right,
                                                   visible: visible))
        #expect(!SidebarGeometry.refitsAfterResize(from: left, to: CGRect(x: 3, y: 0, width: 2053, height: 1259), width: 280, side: .left,
                                                   visible: visible))
        // A corner dragged short of the full width (one horizontal edge and a vertical one): stands.
        #expect(!SidebarGeometry.refitsAfterResize(from: right, to: CGRect(x: 0, y: 630, width: 2000, height: 629), width: 280, side: .right,
                                                   visible: visible))
        #expect(!SidebarGeometry.refitsAfterResize(from: left, to: CGRect(x: 56, y: 0, width: 2000, height: 630), width: 280, side: .left,
                                                   visible: visible))
    }
}
