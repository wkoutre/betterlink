import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Testing
@testable import TabSyncCore

struct SidebarSeamTests {
    let screen = CGRect(x: 0, y: 0, width: 2056, height: 1259)
    let scales: [CGFloat] = [1, 2, 1.5]

    /// The pixel `v` is on, on a screen with `scale` pixels per point, and
    /// how far off that pixel's edge it is.
    private func pixel(_ v: CGFloat, _ scale: CGFloat) -> (on: CGFloat, off: CGFloat) {
        let p = (v * scale).rounded()
        return (p, abs(v * scale - p))
    }

    /// Nick, 2026-11-25: the sidebar's top edge sat 1-2 pt off the browser's.
    @Test func theSidebarsTopBottomAndSeamAreTheWindowsOwnPixelsOnEveryScale() {
        for scale in scales {
            // Odd pixel counts: off the whole-point grid wherever the scale allows.
            let win = CGRect(x: 201 / scale, y: 63 / scale, width: 1801 / scale, height: 1403 / scale)
            for side in SidebarSide.allCases {
                let s = SidebarGeometry.place(window: win, screen: screen, width: 280, side: side, scale: scale).sidebar
                let seam = side == .right ? s.minX : s.maxX, edge = side == .right ? win.maxX : win.minX
                for (mine, its) in [(s.maxY, win.maxY), (s.minY, win.minY), (seam, edge)] {
                    #expect(pixel(mine, scale).on == pixel(its, scale).on, "scale \(scale) \(side): \(mine) for \(its)")
                    #expect(pixel(mine, scale).off < 1e-6, "scale \(scale) \(side): \(mine) is between pixels")
                }
                // The outer edge too, and the sidebar as wide as asked, to the pixel.
                let outer = side == .right ? s.maxX : s.minX
                #expect(pixel(outer, scale).off < 1e-6 && abs(s.width - 280) <= 0.5 / scale + 1e-9, "scale \(scale) \(side): \(s)")
            }
        }
    }

    @Test func aFrameBetweenPixelsGoesToTheNearestOneEdgeByEdge() {
        let win = CGRect(x: 100.3, y: 50.3, width: 899.9, height: 700.5) // to 1000.2 and 750.8
        let two = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .right, scale: 2).sidebar
        #expect(two == CGRect(x: 1000, y: 50.5, width: 280, height: 700.5)) // 50.5 to 751
        let one = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .left, scale: 1).sidebar
        #expect(one == CGRect(x: -180, y: 50, width: 280, height: 701))
        #expect(SidebarSeam.aligned(31.74, scale: 2) == 31.5 && SidebarSeam.aligned(31.76, scale: 2) == 32)
        #expect(SidebarSeam.aligned(31.4, scale: 1.5) == 47 / 1.5)
    }

    /// The window's edges are the sidebar's wherever the window is: it is
    /// never cut to the screen's visible frame, which would leave its top or
    /// bottom short of the window's.
    @Test func aWindowPastTheVisibleFrameKeepsTheSidebarsEdgesOnItsOwn() {
        let win = CGRect(x: 100, y: -40, width: 800, height: 1300) // a point above the visible frame, its bottom under the Dock
        let s = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .right, scale: 2).sidebar
        #expect(s.minY == -40 && s.maxY == 1260)
    }

    @Test func thePanelReachesUnderTheWindowPastItsCornerInWholePixels() {
        for scale in scales {
            for extent in [CGFloat(18.24), 24.5, 25, 39.75] {
                let o = SidebarSeam.overlap(cornerExtent: extent, scale: scale)
                #expect(o >= extent && o < extent + 1 / scale, "scale \(scale) extent \(extent): \(o)")
                #expect(pixel(o, scale).off < 1e-6, "scale \(scale) extent \(extent): \(o)")
            }
        }
        #expect(SidebarSeam.overlap(cornerExtent: 39.75, scale: 1) == 40)
        #expect(SidebarSeam.overlap(cornerExtent: 18.24, scale: 2) == 18.5)
    }

    @Test func besideTheWindowThePanelLiesUnderItsEdgeOnEitherSide() {
        let win = CGRect(x: 400, y: 31, width: 1200, height: 900)
        let right = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .right, scale: 2)
        let o = SidebarSeam.overlap(for: right, cornerExtent: 39.75)
        #expect(o == 40)
        // From 40 pt inside the window's right edge to the sidebar's outer edge.
        #expect(SidebarSeam.panel(for: right, overlap: o) == CGRect(x: 1560, y: 31, width: 320, height: 900))
        let left = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .left, scale: 2)
        // From the sidebar's outer edge to 40 pt inside the window's left edge.
        #expect(SidebarSeam.panel(for: left, overlap: SidebarSeam.overlap(for: left, cornerExtent: 39.75)) == CGRect(x: 120, y: 31, width: 320, height: 900))
        // Top and bottom stay the window's.
        for p in [right, left] {
            let f = SidebarSeam.panel(for: p, overlap: o)
            #expect(f.minY == win.minY && f.maxY == win.maxY)
        }
    }

    @Test func thePanelsOverlapIsInThePixelsOfItsScreen() {
        let win = CGRect(x: 400 / 1.5, y: 31, width: 1200, height: 900)
        let p = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .right, scale: 1.5)
        let o = SidebarSeam.overlap(for: p, cornerExtent: 39.75)
        #expect(o == 60 / 1.5)
        let f = SidebarSeam.panel(for: p, overlap: o)
        #expect(pixel(f.minX, 1.5).off < 1e-6 && pixel(f.maxX, 1.5).off < 1e-6)
        #expect(abs((p.sidebar.minX - f.minX) - o) < 1e-9)
    }

    /// The browser would not make room: the panel covers its edge. Nothing
    /// to reach under, and only on top of the window can it be seen.
    @Test func coveringTheWindowsEdgeThePanelReachesUnderNothingAndStaysAbove() {
        let p = SidebarGeometry.place(window: screen, screen: screen, width: 280, side: .right, keepOnScreen: true, scale: 2)
        #expect(p.overlaps)
        #expect(SidebarSeam.overlap(for: p, cornerExtent: 39.75) == 0)
        #expect(SidebarSeam.panel(for: p, overlap: 0) == CGRect(x: 1776, y: 0, width: 280, height: 1259))
        #expect(SidebarPresence.relation(attached: !p.overlaps) == .above)
    }

    /// During a slide the panel shows from the seam outwards. While the seam
    /// is the window's own edge, it shows the overlap under the window too,
    /// so the window's corners stay filled as it moves.
    @Test func aSlideOpensThePanelFromUnderTheWindowsEdge() {
        #expect(SidebarSeam.reveal(seam: 900, windowEdge: 900, overlap: 40, side: .right) == 860)
        #expect(SidebarSeam.reveal(seam: 500, windowEdge: 500, overlap: 40, side: .left) == 540)
        #expect(SidebarSeam.reveal(seam: 900.2, windowEdge: 900, overlap: 40, side: .right) == 860.2)
    }

    /// The sidebar's edge ahead of the window (one that stays put, or lent
    /// less than the sidebar is wide): nothing more of it shows in the open.
    @Test func aSlideAheadOfTheWindowShowsNoMoreThanTheSidebar() {
        #expect(SidebarSeam.reveal(seam: 1040, windowEdge: 900, overlap: 40, side: .right) == 1040)
        #expect(SidebarSeam.reveal(seam: 360, windowEdge: 500, overlap: 40, side: .left) == 360)
        #expect(SidebarSeam.reveal(seam: 1040, windowEdge: nil, overlap: 40, side: .right) == 1040)
    }
}
