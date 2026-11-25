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
}
