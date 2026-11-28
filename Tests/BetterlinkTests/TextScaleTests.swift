import AppKit
import BetterlinkCore
import Observation
import SwiftUI
import Testing
@testable import Betterlink

/// The chosen text size (General › Text size) reaches what is drawn: the
/// design tokens give their numbers at that size, the window grows for larger
/// text, and every token read is observed, which is what lets a showing view
/// change without being made again.
///
/// The size is one value for the whole process, so every test here puts it
/// back before it returns, and none of them waits while it is changed: a wait
/// lets other tests on the main actor run, and they measure at the standard size.
@MainActor @Suite struct TextScaleTests {
    private func at<T>(_ size: TextSize, _ body: () -> T) -> T {
        TextScale.shared.set(size)
        defer { TextScale.shared.set(.standard) }
        return body()
    }

    private func fitting<V: View>(_ view: V) -> CGSize { NSHostingView(rootView: view).fittingSize }

    private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

    /// The default leaves every number as Design/tokens.json has it.
    @Test func theDefaultIsTheDesignSystemsNumbers() {
        #expect(TextScale.shared.size == .standard)
        #expect(DS.Size.sizeControl == 28)
        #expect(DS.Size.sizeRow == 30)
        #expect(DS.Size.sizeTile == 20)
        #expect(DS.Size.sizeSidebar == 224)
        #expect(DS.text(13) == 13)
        #expect(DS.scaled(26) == 26)
        #expect(BetterlinkWindow.minSize == CGSize(width: 780, height: 540))
        #expect(BetterlinkWindow.defaultSize == CGSize(width: 880, height: 640))
        #expect(TourLayout.column == 520)
    }

    /// Rows, controls and tiles hold text, so they grow and shrink with it, to
    /// whole points.
    @Test func sizesFollowTheText() {
        at(.largest) {
            #expect(near(DS.text(13), 18))
            #expect(DS.Size.sizeRow == 42)
            #expect(DS.Size.sizeControl == 39)
            #expect(DS.Size.sizeSidebar == 310)
        }
        at(.small) {
            #expect(near(DS.text(13), 12))
            #expect(DS.Size.sizeRow == 28)
            #expect(DS.Size.sizeControl == 26)
        }
        #expect(DS.Size.sizeRow == 30)
    }

    /// Larger text gets a larger window, so the page list fits without
    /// scrolling. Smaller text keeps the window as it was.
    @Test func theWindowGrowsForLargerTextOnly() {
        let smallest = BetterlinkWindow.standardMinSize, opens = BetterlinkWindow.standardDefaultSize
        at(.largest) {
            // With no screen in the way.
            #expect(BetterlinkWindow.fitted(smallest, within: nil) == CGSize(width: 1080, height: 748))
            #expect(BetterlinkWindow.fitted(opens, within: nil) == CGSize(width: 1218, height: 886))
            #expect(BetterlinkWindow.defaultSize.width >= BetterlinkWindow.minSize.width)
            #expect(BetterlinkWindow.defaultSize.height >= BetterlinkWindow.minSize.height)
            // The tour's column still fits the smallest window.
            #expect(TourLayout.column + 2 * DS.Space.space8 <= BetterlinkWindow.fitted(smallest, within: nil).width)
        }
        at(.small) {
            #expect(BetterlinkWindow.minSize == smallest)
            #expect(BetterlinkWindow.defaultSize == opens)
        }
    }

    /// The window never asks for more than its screen has: on a small display
    /// the largest text would otherwise put its edges out of reach. It never
    /// goes under its standard size either, as before.
    @Test func theWindowStaysOnASmallScreen() {
        let smallest = BetterlinkWindow.standardMinSize
        let laptop = CGSize(width: 1280, height: 700)
        #expect(BetterlinkWindow.fitted(smallest, scale: TextSize.largest.scale, within: laptop) == CGSize(width: 1080, height: 700))
        #expect(BetterlinkWindow.fitted(smallest, scale: TextSize.larger.scale, within: laptop) == CGSize(width: 960, height: 665))
        let tiny = CGSize(width: 700, height: 500)
        #expect(BetterlinkWindow.fitted(smallest, scale: TextSize.largest.scale, within: tiny) == smallest)
        #expect(BetterlinkWindow.fitted(smallest, scale: TextSize.standard.scale, within: tiny) == smallest)
        // A sheet follows the same rule.
        at(.largest) {
            let sheet = BetterlinkWindow.sheet(800, 480)
            #expect(sheet.width >= 800 && sheet.width <= 1108)
            #expect(sheet.height >= 480 && sheet.height <= 665)
        }
    }

    /// Words, a badge and a button each come out larger at each larger size.
    @Test func whatIsDrawnGrowsWithEachSize() {
        let sizes = TextSize.allCases
        let words = sizes.map { size in at(size) { fitting(Text("Link Rules").font(DS.TextStyle.body)) } }
        let badges = sizes.map { size in at(size) { fitting(StatusBadge(text: "Preview", kind: .neutral)) } }
        let buttons = sizes.map { size in at(size) { fitting(Button("Continue") {}.buttonStyle(.dsPrimary)) } }
        for (smaller, larger) in zip(sizes.indices, sizes.indices.dropFirst()) {
            #expect(words[smaller].width < words[larger].width, "\(sizes[larger]) words")
            #expect(words[smaller].height <= words[larger].height, "\(sizes[larger]) words")
            #expect(badges[smaller].width < badges[larger].width, "\(sizes[larger]) badge")
            #expect(buttons[smaller].height < buttons[larger].height, "\(sizes[larger]) button")
        }
        // The button is as tall as its token says at each size.
        for (size, button) in zip(sizes, buttons) {
            #expect(button.height == CGFloat(size.length(26)), "\(size) button")
        }
    }

    /// Whether what `read` reads is told when the text size changes.
    private func followsTheSize(_ read: () -> Void) -> Bool {
        let told = Told()
        withObservationTracking { read() } onChange: { told.yes = true }
        guard !told.yes else { return false }
        at(.largest) {}
        return told.yes
    }

    /// Reading a token is observed (Observation), and that is the whole of
    /// how a showing view follows the setting: SwiftUI draws a view again
    /// when something its body read changes, so nothing is closed and opened
    /// again. A token read that went around `TextScale` would leave its view
    /// at the old size, and fails here.
    ///
    /// The redraw itself comes on a later turn of the run loop (measured at
    /// once, a showing view still has its old size), and this suite must not
    /// wait while the size is changed, so that half is checked on screen.
    @Test func everyTokenReadFollowsTheSize() {
        #expect(followsTheSize({ _ = DS.TextStyle.body }))
        #expect(followsTheSize({ _ = DS.TextStyle.caption }))
        #expect(followsTheSize({ _ = DS.TextStyle.title1 }))
        #expect(followsTheSize({ _ = DS.TextStyle.code }))
        #expect(followsTheSize({ _ = DS.Size.sizeRow }))
        #expect(followsTheSize({ _ = DS.Size.sizeControl }))
        #expect(followsTheSize({ _ = DS.Size.sizeSidebar }))
        #expect(followsTheSize({ _ = DS.text(10) }))
        #expect(followsTheSize({ _ = DS.scaled(26) }))
        #expect(followsTheSize({ _ = BetterlinkWindow.minSize }))
        #expect(followsTheSize({ _ = TourLayout.column }))
        // What doesn't scale isn't observed: spacing stays as it is.
        #expect(!followsTheSize({ _ = DS.Space.space4 }))
    }

    /// The sidebar's settings menu draws its gear at the image's own size,
    /// so the image is made larger for larger text, like its neighbours.
    @Test func theSidebarsGearGrowsWithTheText() {
        let standard = SidebarView.menuSymbol("gearshape", points: CGFloat(TextSize.standard.points)).size
        let largest = SidebarView.menuSymbol("gearshape", points: CGFloat(TextSize.largest.points)).size
        #expect(standard.height > 0)
        #expect(largest.height > standard.height)
        #expect(largest.width > standard.width)
        #expect(SidebarView.menuSymbol("gearshape", points: 13).isTemplate)
    }

    /// A tour step still fits the window it is read in at every text size
    /// (TourLayoutTests has the standard one).
    @Test func tourStepsFitTheWindowAtEverySize() {
        for size in TextSize.allCases where size != .standard {
            at(size) {
                // The window as it opens with no small screen in the way.
                let window = BetterlinkWindow.fitted(BetterlinkWindow.standardDefaultSize, within: nil)
                let room = window.height - TourLayout.header - TourLayout.footer
                for topic in TourRegistry.topics {
                    for step in topic.steps {
                        let entry = TourPlan.Entry(topic: topic, step: step, note: .updated(step.changed))
                        let view = TourStepContent(entry: entry) { Color.clear.frame(height: TourLayout.controlBudget) }
                        let tall = fitting(view.frame(width: window.width)).height
                        #expect(tall <= room, "\(step.id) is \(tall) pt tall at \(size); the window has \(room) pt.")
                    }
                }
            }
        }
    }
}

/// Set from Observation's change notice, which may come from any thread.
private final class Told: @unchecked Sendable {
    var yes = false
}
