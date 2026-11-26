import AppKit
import Testing
import TabSyncCore
@testable import Betterlink

@MainActor @Suite struct SidebarCornerTests {
    /// A corner's curve: widest at the edge, only narrowing from there, gone
    /// before the depth it was drawn to, and no wider than its span.
    private func expectACorner(_ c: ContinuousCorner, _ what: String) {
        let insets = c.profile.map(\.1)
        #expect(insets.count > 8 && insets.last == 0, "\(what): \(insets.count) rows")
        #expect(zip(insets, insets.dropFirst()).allSatisfy { $0 >= $1 - 1e-9 }, "\(what): the curve widens again")
        #expect(c.span > 0 && (insets.first ?? 0) > 0 && (insets.first ?? 0) <= c.span, "\(what): span \(c.span), widest \(insets.first ?? -1)")
    }

    /// The sidebar's outer corners are those macOS gives a window of a
    /// browser's style here, read from a window that is never shown.
    @Test func theOuterCornerIsReadFromASystemWindowOfABrowsersStyle() throws {
        let read = try #require(ContinuousCorner(windowStyle: ContinuousCorner.browserStyle, toolbar: false))
        expectACorner(read, "a window's corner")
        #expect(ContinuousCorner.window.profile.map(\.1) == read.profile.map(\.1))
        #expect(SidebarPanel.corner.profile.map(\.1) == read.profile.map(\.1))
    }

    /// How far the panel reaches under its window covers the largest corner
    /// macOS gives a window (one with a toolbar), not only a browser's.
    @Test func thePanelReachesAsFarAsTheLargestSystemCorner() throws {
        let plain = try #require(ContinuousCorner(windowStyle: ContinuousCorner.browserStyle, toolbar: false))
        let toolbar = try #require(ContinuousCorner(windowStyle: ContinuousCorner.browserStyle, toolbar: true))
        expectACorner(toolbar, "a toolbar window's corner")
        #expect(toolbar.span >= plain.span)
        #expect(SidebarPanel.reach == toolbar.span)
        #expect(SidebarSeam.overlap(cornerExtent: SidebarPanel.reach, scale: 2) >= plain.span)
    }

    /// Should macOS stop answering, a drawn curve stands in.
    @Test func aDrawnCurveStandsInWhenTheSystemsCantBeRead() {
        let c = ContinuousCorner(radius: 16)
        expectACorner(c, "the drawn corner")
        // A continuous corner runs about one and a half radii along the edge.
        #expect(c.span > 16 && c.span < 16 * 1.6)
    }

    private let corner = ContinuousCorner(radius: 16)
    private let bounds = CGRect(x: 0, y: 0, width: 320, height: 600)

    private func outline(_ side: SidebarSide?, reveal: CGFloat? = nil) -> CGPath {
        SidebarPanel.outline(in: bounds, side: side, reveal: reveal, corner: corner)
    }

    /// Beside a window: square where it lies under the window (the window's
    /// own corners are drawn over it there), rounded at its two outer corners.
    @Test func besideAWindowThePanelIsSquareUnderItAndRoundedOutside() {
        let right = outline(.right) // the window to the left
        for under in [CGPoint(x: 0.5, y: 599.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 30, y: 599.5)] { #expect(right.contains(under), "\(under)") }
        for cut in [CGPoint(x: 319.5, y: 599.5), CGPoint(x: 319.5, y: 0.5)] { #expect(!right.contains(cut), "\(cut)") }
        #expect(right.contains(CGPoint(x: 319.5, y: 300)) && right.contains(CGPoint(x: 300, y: 599.5 - 16)))
        let left = outline(.left) // the window to the right
        for under in [CGPoint(x: 319.5, y: 599.5), CGPoint(x: 319.5, y: 0.5)] { #expect(left.contains(under), "\(under)") }
        for cut in [CGPoint(x: 0.5, y: 599.5), CGPoint(x: 0.5, y: 0.5)] { #expect(!left.contains(cut), "\(cut)") }
    }

    @Test func coveringAWindowsEdgeThePanelIsRoundedAllRound() {
        let all = outline(nil)
        for cut in [CGPoint(x: 0.5, y: 599.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 319.5, y: 599.5), CGPoint(x: 319.5, y: 0.5)] {
            #expect(!all.contains(cut), "\(cut)")
        }
        #expect(all.contains(CGPoint(x: 160, y: 300)))
    }

    /// During a slide only the strip from the reveal line to the outer edge
    /// shows: square at the line, rounded at the outer corners.
    @Test func aSlideShowsOnlyTheStripOutwardsFromItsLine() {
        let right = outline(.right, reveal: 100)
        #expect(!right.contains(CGPoint(x: 99, y: 300)) && right.contains(CGPoint(x: 101, y: 300)))
        #expect(right.contains(CGPoint(x: 100.5, y: 599.5)) && !right.contains(CGPoint(x: 319.5, y: 599.5)))
        let left = outline(.left, reveal: 220)
        #expect(left.contains(CGPoint(x: 219, y: 300)) && !left.contains(CGPoint(x: 221, y: 300)))
        #expect(left.contains(CGPoint(x: 219.5, y: 0.5)) && !left.contains(CGPoint(x: 0.5, y: 0.5)))
        // Nothing yet: the line is at the outer edge.
        #expect(outline(.right, reveal: 320).isEmpty && outline(.left, reveal: 0).isEmpty)
    }
}
