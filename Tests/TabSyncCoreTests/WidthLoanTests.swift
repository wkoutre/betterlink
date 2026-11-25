import CoreGraphics
import Testing
@testable import TabSyncCore

/// The sidebar and its window are one: showing takes width, hiding gives it
/// back. Each test says where the window went in between.
@Suite struct WidthLoanTests {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1049)
    private let second = CGRect(x: 1920, y: -200, width: 2560, height: 1400)

    /// Shows the sidebar beside a window that takes `error` points off what it is asked.
    private func show(_ tile: CGRect, _ side: SidebarSide, width: CGFloat = 280, error: CGFloat = 0, minWidth: CGFloat = 500,
                      screen s: CGRect? = nil) -> (loan: WidthLoan, window: CGRect) {
        let s = s ?? screen
        let inner = SidebarGeometry.settled(window: tile, screen: s, width: width, side: side, minWindowWidth: minWidth) ?? tile
        var got = inner
        got.size.width = max(minWidth, inner.width - error)
        if side == .left { got.origin.x += inner.width - got.width }
        let asked = WidthLoan(outer: tile, inner: inner, side: side)
        return (asked.settled(at: got, screen: s, justAsked: true) ?? WidthLoan(outer: got, inner: got, side: side), got)
    }

    private var tiles: [CGRect] {
        [CGRect(x: 0, y: 0, width: 960, height: 1049), CGRect(x: 960, y: 0, width: 960, height: 1049), screen,
         CGRect(x: 0, y: 0, width: 1280, height: 1049), CGRect(x: 300, y: 100, width: 1620, height: 800)]
    }

    /// Nick, 2026-11-25: a window snapped left, the sidebar shown on the left and
    /// hidden again. The browser need not land exactly where it was asked.
    @Test func hidingGivesBackWhatShowingTook() {
        for tile in tiles {
            for side in SidebarSide.allCases {
                for error in [CGFloat(0), 1, 3, 8] {
                    let (loan, window) = show(tile, side, error: error)
                    #expect(loan.givenBack(from: window, screen: screen) == tile, "\(tile) \(side) off by \(error)")
                }
            }
        }
    }

    @Test func movingThePairMovesWhatIsGivenBack() {
        let tile = CGRect(x: 0, y: 0, width: 960, height: 1049)
        for side in SidebarSide.allCases {
            let (loan, window) = show(tile, side)
            let moved = window.offsetBy(dx: 137, dy: -40)
            let after = loan.settled(at: moved, screen: screen, justAsked: false)
            #expect(after?.givenBack(from: moved, screen: screen) == tile.offsetBy(dx: 137, dy: -40), "\(side)")
            // Hidden in the same breath, before the window settled.
            #expect(loan.givenBack(from: moved, screen: screen) == tile.offsetBy(dx: 137, dy: -40), "\(side)")
        }
    }

    @Test func resizingTheWindowKeepsTheLoan() throws {
        let tile = CGRect(x: 0, y: 0, width: 960, height: 1049)
        for side in SidebarSide.allCases {
            let (loan, window) = show(tile, side)
            var taller = window
            taller.size.height -= 133; taller.size.width += 61
            let after = try #require(loan.settled(at: taller, screen: screen, justAsked: false))
            let back = after.givenBack(from: taller, screen: screen)
            #expect(back.width == taller.width + 280 && back.height == taller.height, "\(side)")
            #expect(side == .left ? back.maxX == taller.maxX : back.minX == taller.minX, "\(side)")
        }
    }

    @Test func movingToAnotherDisplayKeepsTheLoan() throws {
        let (loan, window) = show(CGRect(x: 0, y: 0, width: 960, height: 1049), .left)
        let there = CGRect(x: 2300, y: 11, width: window.width, height: window.height)
        let after = try #require(loan.settled(at: there, screen: second, justAsked: false))
        #expect(after.givenBack(from: there, screen: second).width == 960)
    }

    /// Snapped again: the new tile is the pair's, so the window starts over.
    @Test func snappingAgainEndsTheLoan() {
        let (loan, _) = show(CGRect(x: 0, y: 0, width: 960, height: 1049), .left)
        #expect(loan.settled(at: CGRect(x: 960, y: 0, width: 960, height: 1049), screen: screen, justAsked: false) == nil)
        // Hidden before it settled: the window keeps the tile it was just given.
        let right = CGRect(x: 960, y: 0, width: 960, height: 1049)
        #expect(loan.givenBack(from: right, screen: screen) == right)
    }

    /// A browser that stops at its own minimum gave less; only that comes back.
    @Test func atItsMinimumWidthTheWindowGetsItsTileBack() {
        let tile = CGRect(x: 0, y: 0, width: 640, height: 1049)
        let (loan, window) = show(tile, .left, minWidth: 600)
        #expect(loan.givenBack(from: window, screen: screen).width == tile.width)
    }

    /// Never off the screen it is on.
    @Test func whatIsGivenBackStaysOnTheScreen() throws {
        let (loan, window) = show(CGRect(x: 0, y: 0, width: 960, height: 1049), .left)
        let edge = CGRect(x: 100, y: 0, width: window.width, height: 1049)
        let back = loan.givenBack(from: edge, screen: screen)
        #expect(back.minX >= screen.minX && back.maxX == edge.maxX)
    }

    @Test func showHideShowHideNeverDrifts() {
        var window = CGRect(x: 0, y: 0, width: 960, height: 1049)
        for i in 0..<20 {
            let (loan, shown) = show(window, .left, width: 280, error: CGFloat(i % 5))
            window = loan.givenBack(from: shown, screen: screen)
        }
        #expect(window == CGRect(x: 0, y: 0, width: 960, height: 1049))
    }
}
