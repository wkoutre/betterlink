import AppKit
import BetterlinkCore
import SwiftUI
import Testing
@testable import Betterlink

/// The chosen text size (General › Text size) reaches what is drawn: the
/// design tokens give their numbers at that size, the window grows for larger
/// text, and a view that is already showing changes without being made again.
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
        at(.largest) {
            #expect(BetterlinkWindow.minSize == CGSize(width: 1080, height: 748))
            #expect(BetterlinkWindow.defaultSize.width >= BetterlinkWindow.minSize.width)
            // The tour's column still fits the smallest window.
            #expect(TourLayout.column + 2 * DS.Space.space8 <= BetterlinkWindow.minSize.width)
        }
        at(.small) {
            #expect(BetterlinkWindow.minSize == CGSize(width: 780, height: 540))
            #expect(BetterlinkWindow.defaultSize == CGSize(width: 880, height: 640))
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

    /// A view that reads the tokens the way the app's views do: in its body.
    private struct Row: View {
        var body: some View {
            HStack {
                Text("A tab's title").font(DS.TextStyle.body)
                Spacer(minLength: 0)
                StatusBadge(text: "Preview", kind: .neutral)
            }
            .frame(minHeight: DS.Size.sizeRow)
        }
    }

    /// Changing the size reaches a view that is already showing: nothing has
    /// to be closed and opened again. It ends up as a view made at that size.
    ///
    /// Measured by asking SwiftUI itself (`sizeThatFits`), which draws what
    /// has changed before it answers. An `NSHostingView`'s `fittingSize` is
    /// AppKit's, and keeps its last answer until the next turn of the run
    /// loop, which this test must not wait for (see the suite's note).
    @Test func aShowingViewChangesWithTheSize() {
        let room = CGSize(width: 300, height: 10_000)
        let showing = NSHostingController(rootView: Row().frame(width: 300))
        let before = showing.sizeThatFits(in: room)
        #expect(before.height == 30)
        for size in [TextSize.largest, .small, .larger] {
            let (changed, fresh) = at(size) {
                (showing.sizeThatFits(in: room), NSHostingController(rootView: Row().frame(width: 300)).sizeThatFits(in: room))
            }
            #expect(changed == fresh, "\(size)")
            #expect(changed.height == CGFloat(size.length(30)), "\(size)")
        }
        #expect(showing.sizeThatFits(in: room) == before)
    }

    /// A tour step still fits the window it is read in at every text size
    /// (TourLayoutTests has the standard one).
    @Test func tourStepsFitTheWindowAtEverySize() {
        for size in TextSize.allCases where size != .standard {
            at(size) {
                let window = BetterlinkWindow.defaultSize
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
