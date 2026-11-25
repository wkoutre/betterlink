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
        // Lands by its own rounding, keeping the tile's far edge.
        let asked = WidthLoan.asking(outer: tile, inner: inner, side: side)
        let seen = asked.seen(at: got, screen: s)
        return (seen.loan ?? asked, seen.correction ?? got)
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
                    if loan.taken < 10 && SidebarGeometry.settled(window: tile, screen: screen, width: 280, side: side) == nil { continue } // room beside it: nothing was lent
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
            let after = loan.seen(at: moved, screen: screen).loan
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
            let after = try #require(loan.seen(at: taller, screen: screen).loan)
            let back = after.givenBack(from: taller, screen: screen)
            #expect(back.width == taller.width + 280 && back.height == taller.height, "\(side)")
            #expect(side == .left ? back.maxX == taller.maxX : back.minX == taller.minX, "\(side)")
        }
    }

    @Test func movingToAnotherDisplayKeepsTheLoan() throws {
        let (loan, window) = show(CGRect(x: 0, y: 0, width: 960, height: 1049), .left)
        let there = CGRect(x: 2300, y: 11, width: window.width, height: window.height)
        let after = try #require(loan.seen(at: there, screen: second).loan)
        #expect(after.givenBack(from: there, screen: second).width == 960)
    }

    /// Snapped again: the new tile is the pair's, so the window starts over.
    @Test func snappingAgainEndsTheLoan() {
        let (loan, _) = show(CGRect(x: 0, y: 0, width: 960, height: 1049), .left)
        #expect(loan.seen(at: CGRect(x: 960, y: 0, width: 960, height: 1049), screen: screen).loan == nil)
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

    /// Past the screen's edge already: hiding takes it no further.
    @Test func hidingNeverPushesAWindowFurtherOffTheScreen() {
        for side in SidebarSide.allCases {
            for past in [CGFloat(0.5), 10, 200, 600] {
                let w = CGRect(x: 0, y: 0, width: 680, height: 900)
                let frame = side == .left ? w.offsetBy(dx: -past, dy: 0) : w.offsetBy(dx: 1920 - 680 + past, dy: 0)
                let loan = WidthLoan.lent(outer: CGRect(x: 0, y: 0, width: 960, height: 900), inner: CGRect(x: 280, y: 0, width: 680, height: 900), side: side)
                let back = loan.givenBack(from: frame, screen: screen)
                #expect(side == .left ? back.minX >= frame.minX : back.maxX <= frame.maxX, "\(side) \(past) \(back)")
                #expect(side == .left ? abs(back.maxX - frame.maxX) < 1 : abs(back.minX - frame.minX) < 1)
            }
        }
    }

    /// A browser that hasn't narrowed yet has lent nothing, and one that never
    /// does never will have: dragged off, hiding leaves its width alone.
    @Test func askingLendsNothing() {
        for tile in [CGRect(x: 100, y: 50, width: 1500, height: 800), CGRect(x: 0, y: 0, width: 960, height: 1049)] {
            for side in SidebarSide.allCases {
                let inner = side == .left ? CGRect(x: tile.minX + 280, y: tile.minY, width: tile.width - 280, height: tile.height)
                                          : CGRect(x: tile.minX, y: tile.minY, width: tile.width - 280, height: tile.height)
                let loan = WidthLoan.asking(outer: tile, inner: inner, side: side)
                #expect(loan.taken == 0)
                #expect(loan.givenBack(from: tile, screen: screen) == tile)
                let dragged = CGRect(x: 250, y: 60, width: tile.width, height: 900)
                #expect(loan.givenBack(from: dragged, screen: screen) == dragged)
                #expect(loan.seen(at: dragged, screen: screen).loan == nil)
            }
        }
    }

    /// Late, and from the wrong side: the width it gave counts, and it is put
    /// where that width belongs, its far edge where it was.
    @Test func aLateAnswerLendsWhatItGave() throws {
        let tile = CGRect(x: 0, y: 0, width: 960, height: 1049)
        let loan = WidthLoan.asking(outer: tile, inner: CGRect(x: 280, y: 0, width: 680, height: 1049), side: .left)
        #expect(loan.seen(at: tile, screen: screen).loan == loan)
        let wrong = CGRect(x: 0, y: 0, width: 680, height: 1049)
        let seen = loan.seen(at: wrong, screen: screen)
        #expect(seen.correction == CGRect(x: 280, y: 0, width: 680, height: 1049))
        let lent = try #require(seen.loan)
        #expect(lent.taken == 280)
        #expect(lent.givenBack(from: seen.correction!, screen: screen) == tile)
        // Hidden before the correction took: still the whole tile.
        #expect(loan.givenBack(from: wrong, screen: screen) == tile)
    }

    /// A pair shifted so both fit the screen (a browser at its minimum) is where
    /// it was asked to be.
    @Test func aShiftedPairIsNotCorrected() throws {
        let tile = CGRect(x: 1371, y: 0, width: 685, height: 1049), big = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        let inner = try #require(SidebarGeometry.settled(window: tile, screen: big, width: 280, side: .right, minWindowWidth: 500))
        let seen = WidthLoan.asking(outer: tile, inner: inner, side: .right).seen(at: inner, screen: big)
        #expect(seen.correction == nil)
        #expect(seen.loan?.givenBack(from: inner, screen: big) == tile)
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
