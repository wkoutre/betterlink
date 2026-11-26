import AppKit
import Testing
import TabSyncCore
@testable import Betterlink

/// The panel's mask: `SidebarSeam.mask`'s pixels as a path in the panel's
/// points, the right way up.
@MainActor @Suite struct SidebarPanelShapeTests {
    private let bounds = CGRect(x: 0, y: 0, width: 311, height: 600) // a 280 pt sidebar, 31 pt over its window
    private let corner = WindowCorner.pixels(radius: 20, scale: 2)

    /// The middle of pixel `i`, `j` (from the left, from the top), in points, y up.
    private func pixel(_ i: Int, _ j: Int) -> CGPoint { CGPoint(x: (CGFloat(i) + 0.5) / 2, y: 600 - (CGFloat(j) + 0.5) / 2) }

    @Test func thePathIsTheMaskTheRightWayUp() {
        let right = SidebarPanel.outline(in: bounds, scale: 2, side: .right, reach: 31, radius: 20, reveal: nil)
        // The window's corner at the top of the seam: the pixel in it is filled, top and bottom.
        #expect(corner.notch[0][0] == 1)
        #expect(right.contains(pixel(61, 0)) && right.contains(pixel(61, 1199)))
        // The strip over the window, clear of the corners, is not the panel's.
        #expect(!right.contains(pixel(30, 600)) && !right.contains(pixel(0, 0)))
        // The body is, and its outer corners are cut.
        #expect(right.contains(pixel(62, 600)) && right.contains(pixel(621, 600)) && right.contains(pixel(300, 0)))
        #expect(!right.contains(pixel(621, 0)) && !right.contains(pixel(621, 1199)))
        let left = SidebarPanel.outline(in: bounds, scale: 2, side: .left, reach: 31, radius: 20, reveal: nil)
        #expect(left.contains(pixel(560, 0)) && !left.contains(pixel(600, 600)) && !left.contains(pixel(0, 0)) && left.contains(pixel(0, 600)))
    }

    @Test func aSlideShowsTheStripFromItsLineInPoints() {
        let right = SidebarPanel.outline(in: bounds, scale: 2, side: .right, reach: 31, radius: 20, reveal: 200)
        #expect(!right.contains(pixel(399, 600)) && right.contains(pixel(400, 600)) && !right.contains(pixel(61, 0)))
        #expect(SidebarPanel.outline(in: bounds, scale: 2, side: .right, reach: 31, radius: 20, reveal: 311).isEmpty)
    }

    @Test func aWindowOfAnotherRadiusGetsItsOwnCorner() {
        // 16 pt reaches 25 pt over the window: its corner is over sooner along the top.
        let small = SidebarPanel.outline(in: CGRect(x: 0, y: 0, width: 305, height: 600), scale: 2, side: .right, reach: 25, radius: 16, reveal: nil)
        let c16 = WindowCorner.pixels(radius: 16, scale: 2)
        #expect(c16.side == 50 && corner.side == 62)
        #expect(small.contains(pixel(49, 0)) && !small.contains(pixel(609, 0)))
        // 45 pixels in from the outer corner the 16 pt corner's first row is whole; the 20 pt one's is not yet.
        #expect(c16.window[0][45] > 0.5 && corner.window[0][45] < 0.5)
    }
}
