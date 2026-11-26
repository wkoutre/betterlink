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

    // MARK: - The window's corner radius

    /// What the window server says is used only when it is a radius a window
    /// can have: anything else means the call no longer says what it did.
    @Test func onlyASaneRadiusIsTakenFromTheWindowServer() {
        for r in [CGFloat(4), 10, 16, 20, 26, 40] { #expect(SidebarSeam.radius(reported: r) == r) }
        for r in [CGFloat(0), -3, 3.9, 40.1, 60, 1e9, .infinity, .nan] { #expect(SidebarSeam.radius(reported: r) == nil, "\(r)") }
        #expect(SidebarSeam.radius(reported: nil) == nil)
    }

    /// Chrome's and Brave's windows read 20 on macOS 26.5.2, the only macOS
    /// the call was verified on.
    @Test func theFallbackIsChromesRadiusAndOnlyMacOS26IsTrusted() {
        #expect(SidebarSeam.fallbackRadius == 20)
        #expect(SidebarSeam.radius(reported: SidebarSeam.fallbackRadius) == 20)
        #expect(SidebarSeam.verifiedSystems == [26])
    }

    /// A window's corner is asked for more than once (followed, full screen,
    /// each time it comes to rest). A read that gives nothing says nothing
    /// about the window: asked the moment it leaves full screen, the window
    /// server may not have its corner back yet. The last radius it did give
    /// stands, and the fallback is only for a window never read.
    @Test func aReadThatGivesNothingKeepsTheLastRadiusThatWasRead() {
        #expect(SidebarSeam.radius(read: 16, lastRead: nil) == 16)
        #expect(SidebarSeam.radius(read: nil, lastRead: 16) == 16)
        #expect(SidebarSeam.radius(read: nil, lastRead: 26) == 26)
        // A new answer replaces the old one.
        #expect(SidebarSeam.radius(read: 20, lastRead: 16) == 20)
        // Never read: Chrome's.
        #expect(SidebarSeam.radius(read: nil, lastRead: nil) == SidebarSeam.fallbackRadius)
        // What "nothing" is: a 0 on the way out of full screen is no radius.
        #expect(SidebarSeam.radius(read: SidebarSeam.radius(reported: 0), lastRead: 16) == 16)
    }

    // MARK: - How far the panel reaches over the window

    /// As far as the corner's pixels go, in whole points: AppKit keeps a
    /// window's frame on whole points.
    @Test func thePanelReachesOverTheWholeCornerInWholePoints() {
        for scale in scales {
            for radius in [CGFloat(10), 16, 20, 26, 40] {
                let reach = SidebarSeam.reach(radius: radius, scale: scale)
                let corner = CGFloat(WindowCorner.pixels(radius: radius, scale: scale).side) / scale
                #expect(reach >= corner && reach < corner + 1, "radius \(radius) at \(scale)x: \(reach) for \(corner)")
                #expect(reach == reach.rounded())
            }
        }
        #expect(SidebarSeam.reach(radius: 20, scale: 2) == 31)
        #expect(SidebarSeam.reach(radius: 16, scale: 2) == 25)
        #expect(SidebarSeam.reach(radius: 26, scale: 2) == 41)
    }

    @Test func besideTheWindowThePanelReachesOverItsEdgeOnEitherSide() {
        let win = CGRect(x: 400, y: 31, width: 1200, height: 900)
        let right = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .right, scale: 2)
        let reach = SidebarSeam.reach(for: right, radius: 20)
        #expect(reach == 31)
        // From 31 pt inside the window's right edge to the sidebar's outer edge.
        #expect(SidebarSeam.panel(for: right, reach: reach) == CGRect(x: 1569, y: 31, width: 311, height: 900))
        let left = SidebarGeometry.place(window: win, screen: screen, width: 280, side: .left, scale: 2)
        // From the sidebar's outer edge to 31 pt inside the window's left edge.
        #expect(SidebarSeam.panel(for: left, reach: SidebarSeam.reach(for: left, radius: 20)) == CGRect(x: 120, y: 31, width: 311, height: 900))
        // Top and bottom stay the window's.
        for p in [right, left] {
            let f = SidebarSeam.panel(for: p, reach: reach)
            #expect(f.minY == win.minY && f.maxY == win.maxY)
        }
    }

    /// The browser would not make room: the panel covers its edge. No corner
    /// of the window to fill there.
    @Test func coveringTheWindowsEdgeThePanelReachesOverNothing() {
        let p = SidebarGeometry.place(window: screen, screen: screen, width: 280, side: .right, keepOnScreen: true, scale: 2)
        #expect(p.overlaps)
        #expect(SidebarSeam.reach(for: p, radius: 20) == 0)
        #expect(SidebarSeam.panel(for: p, reach: 0) == CGRect(x: 1776, y: 0, width: 280, height: 1259))
    }

    // MARK: - The panel's shape, pixel by pixel

    /// How much of each pixel a list of rects covers, `w` by `h` pixels, row 0 at the top.
    private func drawn(_ rects: [CGRect], _ w: Int, _ h: Int) -> [[Double]] {
        var g = Array(repeating: Array(repeating: 0.0, count: w), count: h)
        for r in rects {
            for j in max(0, Int(r.minY.rounded(.down)))..<min(h, Int(r.maxY.rounded(.up))) {
                let dy = min(r.maxY, CGFloat(j + 1)) - max(r.minY, CGFloat(j))
                for i in max(0, Int(r.minX.rounded(.down)))..<min(w, Int(r.maxX.rounded(.up))) {
                    let dx = min(r.maxX, CGFloat(i + 1)) - max(r.minX, CGFloat(i))
                    if dx > 0, dy > 0 { g[j][i] += Double(dx * dy) }
                }
            }
        }
        return g
    }

    private let corner = WindowCorner.pixels(radius: 20, scale: 2)
    private let w = 622, h = 400, reach = 62 // a 280 pt sidebar reaching 31 pt over its window, at 2x

    private func expectSame(_ a: Double, _ b: Double, _ what: String) { #expect(abs(a - b) < 1e-9, "\(what): \(a) for \(b)") }

    /// Sidebar on the right, the window to its left: the seam is `reach`
    /// pixels in. Its body is filled, its two outer corners are the window's
    /// own corner mirrored, the seam's two notches are the corner's fill, and
    /// the rest of the strip over the window is clear, so a click there is
    /// the window's.
    @Test func besideAWindowThePanelIsItsBodyItsOuterCornersAndTheSeamsNotches() {
        let n = corner.side
        for side in SidebarSide.allCases {
            let rects = SidebarSeam.mask(width: w, height: h, side: side, reach: reach, corner: corner, reveal: nil)
            let g = drawn(rects, w, h)
            // Column `i` pixels from the outer edge, and from the seam into the window.
            let outer = { (i: Int) in side == .right ? self.w - 1 - i : i }
            let over = { (i: Int) in side == .right ? self.reach - 1 - i : self.w - self.reach + i }
            for j in 0..<n {
                for i in 0..<n {
                    for row in [j, h - 1 - j] {
                        expectSame(g[row][outer(i)], corner.window[j][i], "\(side) outer corner \(i), \(j)")
                        expectSame(g[row][over(i)], corner.notch[j][i], "\(side) notch \(i), \(j)")
                    }
                }
            }
            // Between the corners: all of the body, none of the strip.
            for row in [n, h / 2, h - 1 - n] {
                for i in 0..<(w - reach) { expectSame(g[row][outer(i)], 1, "\(side) body \(i)") }
                for i in 0..<reach { expectSame(g[row][over(i)], 0, "\(side) strip \(i)") }
            }
            for i in n..<(w - reach) { expectSame(g[0][outer(i)], 1, "\(side) top edge \(i)") }
        }
    }

    /// No rect leaves the panel, and each lies on whole pixel rows: only its
    /// width says how much of a pixel is covered.
    @Test func theShapeIsWholePixelRowsInsideThePanel() {
        for side in [SidebarSide.left, .right, nil] {
            for reveal in [nil, CGFloat(200.5)] {
                for r in SidebarSeam.mask(width: w, height: h, side: side, reach: side == nil ? 0 : reach, corner: corner, reveal: reveal) {
                    #expect(r.minX >= 0 && r.maxX <= CGFloat(w) && r.minY >= 0 && r.maxY <= CGFloat(h), "\(r)")
                    #expect(r.minY == r.minY.rounded() && r.maxY == r.maxY.rounded() && r.width > 0 && r.height > 0, "\(r)")
                }
            }
        }
    }

    @Test func coveringAWindowsEdgeThePanelIsRoundedAllRound() {
        let n = corner.side, g = drawn(SidebarSeam.mask(width: 560, height: h, side: nil, reach: 0, corner: corner, reveal: nil), 560, h)
        for j in 0..<n {
            for i in 0..<n {
                for (row, col) in [(j, i), (j, 559 - i), (h - 1 - j, i), (h - 1 - j, 559 - i)] { expectSame(g[row][col], corner.window[j][i], "corner \(i), \(j)") }
            }
        }
        expectSame(g[h / 2][0], 1, "left edge")
        expectSame(g[h / 2][559], 1, "right edge")
    }

    /// During a slide only the strip from the line to the outer edge shows:
    /// its outer corners rounded, square at the line, and no notches (the
    /// window is not at the seam yet).
    @Test func aSlideShowsOnlyTheStripOutwardsFromItsLine() {
        let n = corner.side
        let right = drawn(SidebarSeam.mask(width: w, height: h, side: .right, reach: reach, corner: corner, reveal: 300), w, h)
        expectSame(right[h / 2][299], 0, "inside the line")
        expectSame(right[h / 2][300], 1, "outside the line")
        expectSame(right[0][300], 1, "square at the line")
        expectSame(right[0][w - 1], 0, "rounded outside")
        expectSame(right[5][w - 1 - 3], corner.window[5][3], "the outer corner")
        for j in 0..<n { for i in 0..<reach { expectSame(right[j][i], 0, "no notch \(i), \(j)") } }
        let left = drawn(SidebarSeam.mask(width: w, height: h, side: .left, reach: reach, corner: corner, reveal: 250.5), w, h)
        expectSame(left[h / 2][249], 1, "outside the line")
        expectSame(left[h / 2][250], 0.5, "the line's own pixel")
        expectSame(left[h / 2][251], 0, "inside the line")
        expectSame(left[h - 1][0], 0, "rounded outside")
        // Nothing yet: the line is at the outer edge.
        #expect(SidebarSeam.mask(width: w, height: h, side: .right, reach: reach, corner: corner, reveal: CGFloat(w)).isEmpty)
        #expect(SidebarSeam.mask(width: w, height: h, side: .left, reach: reach, corner: corner, reveal: 0).isEmpty)
    }

    /// A panel too small for its corners is still filled, square.
    @Test func aPanelSmallerThanItsCornersIsAPlainRect() {
        let g = drawn(SidebarSeam.mask(width: 80, height: 60, side: nil, reach: 0, corner: corner, reveal: nil), 80, 60)
        expectSame(g[0][0], 1, "corner")
        expectSame(g[30][40], 1, "middle")
    }
}
