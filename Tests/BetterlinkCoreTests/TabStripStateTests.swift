import Foundation
import Testing
@testable import BetterlinkCore

/// Readings taken from real browsers on 2026-11-25 (frames relative to an
/// 1100 x 800 window): Chrome for Testing 158.0.8127.18 with vertical tabs
/// available, and Brave 158.1.100.59.
@Suite struct TabStripStateTests {
    typealias R = TabStripReading
    typealias Item = TabStripReading.Item
    static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    let unmarked = Item(enabled: true, mark: nil), marked = Item(enabled: true, mark: "✓")

    var chromeTop: R { R(tabs: Self.rect(114, 0, 732, 41), toolbar: Self.rect(0, 40, 1100, 46), tabHeight: 41, show: unmarked, collapse: nil) }
    var chromeVertical: R { R(tabs: Self.rect(0, 0, 240, 800), toolbar: Self.rect(240, 0, 860, 46), tabHeight: 30, show: marked, collapse: unmarked) }
    var chromeCollapsed: R { R(tabs: Self.rect(0, 46, 56, 754), toolbar: Self.rect(108, 0, 992, 46), tabHeight: 30, show: marked, collapse: marked) }
    /// Brave never marks its item: vertical or not, it reads the same.
    var braveTop: R { R(tabs: Self.rect(89, 0, 740, 40), toolbar: Self.rect(0, 40, 1100, 40), tabHeight: 40, show: unmarked, collapse: nil) }
    var braveVertical: R { R(tabs: Self.rect(0, 41, 220, 112), toolbar: Self.rect(0, 0, 1100, 40), tabHeight: 32, show: unmarked, collapse: nil) }

    @Test func theShapeOfTheStripSaysWhereTheTabsAre() {
        #expect(chromeTop.layout == .horizontal)
        #expect(chromeVertical.layout == .vertical)
        #expect(chromeCollapsed.layout == .vertical)
        #expect(braveTop.layout == .horizontal)
        #expect(braveVertical.layout == .vertical)
        #expect(chromeVertical.column == .expanded)
        #expect(chromeCollapsed.column == .collapsed)
        #expect(braveVertical.column == .expanded)
        #expect(chromeTop.column == .unknown)
    }

    /// Nick, 2026-11-25: Brave with vertical tabs went top bar, vertical, top
    /// bar on every return. Vertical tabs seen: nothing is pressed.
    @Test func braveWithVerticalTabsIsLeftAlone() {
        #expect(braveVertical.next == nil)
    }

    @Test func tabsAcrossTheTopAreSwitchedOnceThenCollapsedWhereTheBrowserCan() {
        #expect(braveTop.next == .showVertically)
        #expect(chromeTop.next == .showVertically)
        #expect(chromeVertical.next == .collapse)
        #expect(chromeCollapsed.next == nil)
        // What a press must have done, seen in the window, not the menu.
        #expect(braveVertical.shows(.showVertically) && chromeVertical.shows(.showVertically))
        #expect(!braveTop.shows(.showVertically) && !chromeTop.shows(.showVertically))
        #expect(chromeCollapsed.shows(.collapse) && !chromeVertical.shows(.collapse))
    }

    @Test func whatCannotBeSeenIsNeverPressed() {
        // No tab strip or no toolbar found (full screen, another kind of window).
        var r = chromeTop; r.tabs = nil
        #expect(r.layout == .unknown && r.next == nil)
        r = braveTop; r.toolbar = nil
        #expect(r.layout == .unknown && r.next == nil)
        // A strip that is neither above nor beside nor below the toolbar.
        r = chromeTop; r.tabs = Self.rect(114, 20, 732, 60)
        #expect(r.layout == .unknown && r.next == nil)
        // The item is missing, disabled (Chrome without the feature), or its state can't be read.
        r = chromeTop; r.show = nil
        #expect(r.next == nil)
        r = chromeTop; r.show = Item(enabled: false, mark: nil)
        #expect(r.next == nil)
        r = chromeTop; r.show = Item(enabled: nil, mark: nil)
        #expect(r.next == nil)
        // The menu says vertical, the window says top: they disagree.
        r = chromeTop; r.show = marked
        #expect(r.next == nil)
        // Vertical, but how wide the column is can't be told, or the menu says collapsed already.
        r = chromeVertical; r.tabHeight = nil
        #expect(r.column == .unknown && r.next == nil)
        r = chromeVertical; r.tabs = Self.rect(0, 0, 90, 800)
        #expect(r.column == .unknown && r.next == nil)
        r = chromeVertical; r.collapse = marked
        #expect(r.next == nil)
        r = chromeVertical; r.collapse = Item(enabled: false, mark: nil)
        #expect(r.next == nil)
    }

    // MARK: - One window's takeover, look by look

    typealias Flow = TabStripTakeoverFlow

    private func run(_ looks: [R]) -> [Flow.Step] {
        var flow = Flow(), steps: [Flow.Step] = []
        for r in looks {
            steps.append(flow.step(r))
            if steps.last == .done || steps.last == .undecided || steps.last.map({ if case .pressBack = $0 { true } else { false } }) == true { break }
        }
        return steps
    }

    @Test func aWindowAlreadyCollapsedIsLookedAtOnceAndLeft() {
        #expect(run([chromeCollapsed]) == [.done])
    }

    /// Brave with vertical tabs (Nick's report): looked at a few times in case
    /// the browser comes to offer Collapse, and never pressed.
    @Test func braveWithVerticalTabsIsLookedAtAndNeverPressed() {
        #expect(run(Array(repeating: braveVertical, count: Flow.settling + 2)) == Array(repeating: .lookAgain, count: Flow.settling - 1) + [.done])
    }

    /// The browser's menu follows the focused window a moment late: a window
    /// that comes forward expanded while the menu still shows the last
    /// window's checkmark is looked at again, and collapsed once they agree.
    @Test func aMenuStillShowingTheLastWindowIsWaitedFor() {
        var stale = chromeVertical; stale.collapse = marked
        #expect(run([stale, stale, chromeVertical, chromeCollapsed]) == [.lookAgain, .lookAgain, .press(.collapse), .done])
        var staleTop = chromeTop; staleTop.show = marked
        #expect(run([staleTop, chromeTop, chromeCollapsed]) == [.lookAgain, .press(.showVertically), .done])
        // They never agree: left as it is, nothing pressed.
        // They never agree in this run: nothing pressed, and the window is not
        // written off: its next time in front gets a new run.
        #expect(run(Array(repeating: stale, count: Flow.settling + 2)) == Array(repeating: .lookAgain, count: Flow.settling - 1) + [.undecided])
        #expect(run(Array(repeating: staleTop, count: Flow.settling + 2)).last == .undecided)
        // The menu was measured to catch up 0.5 to 0.75 s after a window comes
        // forward: the wait is about three times that, and its own number.
        #expect(Flow.settling >= 6 && Flow.settling != Flow.patience)
        #expect(stale.summary == "vertical expanded, show ✓ collapse ✓")
        #expect(chromeTop.summary == "horizontal unknown, show off collapse none")
    }

    /// A window still opening has no tabs to see yet: it is looked at again
    /// before it is left alone, and is taken over once it can be seen. A
    /// browser with no such menu item (Arc, Dia) is done at the first look.
    @Test func aWindowNotYetReadableIsLookedAtAgain() {
        var unseen = chromeTop; unseen.tabs = nil
        #expect(run(Array(repeating: unseen, count: Flow.settling + 2)) == Array(repeating: .lookAgain, count: Flow.settling - 1) + [.done])
        #expect(run([unseen, chromeTop, chromeCollapsed]) == [.lookAgain, .press(.showVertically), .done])
        #expect(run([R(tabs: nil, toolbar: nil, tabHeight: nil, show: nil, collapse: nil)]) == [.done])
    }

    /// Brave has no Collapse item: one press, seen to have worked, then done.
    @Test func braveAcrossTheTopIsSwitchedOnce() {
        #expect(run([braveTop] + Array(repeating: braveVertical, count: Flow.settling + 1)) == [.press(.showVertically)] + Array(repeating: .lookAgain, count: Flow.settling - 1) + [.done])
    }

    /// Chrome offers Collapse a moment after it goes vertical, and the column
    /// narrows over a few frames: both are waited for, nothing is pressed twice.
    @Test func chromeIsSwitchedThenCollapsedOnceItCanBe() {
        var notYet = chromeVertical; notYet.collapse = nil
        var narrowing = chromeVertical; narrowing.tabs = Self.rect(0, 0, 100, 800); narrowing.collapse = marked
        #expect(run([chromeTop, notYet, chromeVertical, narrowing, chromeCollapsed])
                == [.press(.showVertically), .lookAgain, .press(.collapse), .lookAgain, .done])
    }

    /// A press is pressed back only when the window is seen, look after look,
    /// still in the state it was in: then that is the end for this browser.
    @Test func aPressSeenNotToHaveWorkedIsPressedBack() {
        let wait = Array(repeating: Flow.Step.lookAgain, count: Flow.patience - 1)
        #expect(run([braveTop] + Array(repeating: braveTop, count: Flow.patience)) == [.press(.showVertically)] + wait + [.pressBack(.showVertically)])
        #expect(run([chromeVertical] + Array(repeating: chromeVertical, count: Flow.patience)) == [.press(.collapse)] + wait + [.pressBack(.collapse)])
        // A slow browser: it shows on the last look, nothing is pressed back.
        #expect(run([braveTop] + Array(repeating: braveTop, count: Flow.patience - 1) + [braveVertical]).contains(.pressBack(.showVertically)) == false)
    }

    /// After a press the window can't be seen (or the column's width can't be
    /// told): nothing more is pressed, not even back.
    @Test func aPressWhoseResultCannotBeSeenIsLeftAsItIs() {
        var unseen = braveTop; unseen.toolbar = nil
        let steps = run([braveTop] + Array(repeating: unseen, count: Flow.patience + 2))
        #expect(steps.first == .press(.showVertically) && steps.last == .done)
        #expect(steps.filter { $0 != .lookAgain }.count == 2)
        var between = chromeVertical; between.tabs = Self.rect(0, 0, 100, 800); between.collapse = marked
        let collapse = run([chromeVertical] + Array(repeating: between, count: Flow.patience + 2))
        #expect(collapse.first == .press(.collapse) && collapse.last == .done && collapse.filter { $0 != .lookAgain }.count == 2)
    }

    @Test func neverMoreThanTheTwoPressesAndItEnds() {
        // A browser that flips back and forth whatever is pressed.
        let looks = Array(repeating: [chromeTop, chromeVertical], count: 10).flatMap { $0 }
        let steps = run(looks)
        #expect(steps.filter { if case .press = $0 { true } else { false } }.count <= 2)
        #expect(steps.count < looks.count)
    }
}
