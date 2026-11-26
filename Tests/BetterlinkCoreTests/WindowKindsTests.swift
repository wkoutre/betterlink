import Foundation
import Testing
@testable import BetterlinkCore

/// Readings taken live on 2026-11-25 with throwaway profiles, Chrome for
/// Testing 158 and Brave 158 alike, and from Dia read only. Every window here
/// is an AXWindow/AXStandardWindow with close, minimize, zoom and full screen
/// buttons. A tab group is an AXTabGroup, a tab an AXTabButton in one.
@Suite struct WindowKindsTests {
    typealias R = WindowKinds.Reading

    /// A normal window: one tab group, with the tabs across the top, in a
    /// column or the column collapsed.
    let normal = R(tabGroups: 1, tabs: 1)
    /// window.open with "popup" (an extension's palette): a toolbar with an
    /// address field, no tabs.
    let popup = R(tabGroups: 0, tabs: 0)
    /// --app=URL, and DevTools on its own: neither tabs nor toolbar.
    let appWindow = R(tabGroups: 0, tabs: 0)
    /// Dia's own browser window: about 82 elements, none of them a tab group.
    let dia = R(tabGroups: 0, tabs: 0)

    /// As many looks without tabs as a window gets before it is not one.
    let looks = 1 + WindowKinds.waits.count

    @Test func inABrowserSeenWithTabsOnlyAWindowSeenWithThemIsABrowserWindow() {
        var k = WindowKinds()
        k.saw([1: normal])
        #expect(k.readable)
        #expect(k.kind(of: 1) == .browser)
        k.saw([2: popup])
        #expect(k.kind(of: 2) != .browser)
        k.saw([3: appWindow])
        #expect(k.kind(of: 3) != .browser)
        // A second normal window, tabs there at the first look.
        k.saw([4: normal])
        #expect(k.kind(of: 4) == .browser && k.wait(for: 4) == nil)
    }

    /// betterlink starting beside a browser with a palette open: the windows
    /// come in any order, and all are read before any is judged.
    @Test func aPopupReadInTheSameLookAsANormalWindowIsNeverABrowserWindow() {
        var k = WindowKinds()
        k.saw([2: popup, 1: normal])
        #expect(k.kind(of: 1) == .browser)
        #expect(k.kind(of: 2) == .unknown)
    }

    @Test func aWindowNotKnownYetGetsAFewMoreLooksThenIsNotOne() {
        var k = WindowKinds()
        k.saw([1: normal])
        var waited: TimeInterval = 0
        for look in 1...looks {
            #expect(k.kind(of: 2) == .unknown, "before look \(look)")
            k.saw([2: popup])
            waited += k.wait(for: 2) ?? 0
        }
        #expect(k.kind(of: 2) == .notBrowser)
        #expect(k.wait(for: 2) == nil)
        // Bounded: five more looks over three seconds, then none.
        #expect(looks == 6)
        #expect(abs(waited - 3.0) < 0.001)
    }

    @Test func aWindowStillOpeningIsABrowserWindowOnceItsTabsShowAndStaysOne() {
        var k = WindowKinds()
        k.saw([1: normal])
        k.saw([2: R(tabGroups: 0, tabs: 0)])
        #expect(k.kind(of: 2) == .unknown && k.wait(for: 2) == WindowKinds.waits[0])
        // The group is there before its tabs are.
        k.saw([2: R(tabGroups: 1, tabs: 0)])
        #expect(k.kind(of: 2) == .unknown && k.wait(for: 2) == WindowKinds.waits[1])
        k.saw([2: normal])
        #expect(k.kind(of: 2) == .browser && k.wait(for: 2) == nil)
        #expect(k.sawTabs(in: 2))
        // Its tabs out of sight later (full screen, the tab strip changing
        // places): still a browser window.
        for _ in 0..<10 { k.saw([2: R(tabGroups: 0, tabs: 0)]) }
        #expect(k.kind(of: 2) == .browser)
    }

    /// Dia: no window of it shows a tab group, so none is taken away.
    @Test func aBrowserNeverSeenWithTabsKeepsEveryWindow() {
        var k = WindowKinds()
        for _ in 0..<20 { k.saw([1: dia, 2: dia]) }
        #expect(!k.readable)
        #expect(k.kind(of: 1) == .browser && k.kind(of: 2) == .browser)
        #expect(k.wait(for: 1) == nil)
        // One not looked at yet, too.
        #expect(k.kind(of: 3) == .browser)
        // A tab group with no tab in it shows nothing about the browser.
        k.saw([4: R(tabGroups: 1, tabs: 0)])
        #expect(!k.readable && k.kind(of: 4) == .browser)
    }

    /// A browser launched with only an app window, a normal one opened later:
    /// the app window was kept, and goes only after its own looks.
    @Test func aWindowKeptBeforeItsBrowserShowedTabsGetsItsLooksThenIsNotOne() {
        var k = WindowKinds()
        for _ in 0..<10 { k.saw([1: appWindow]) }
        #expect(k.kind(of: 1) == .browser)
        k.saw([2: normal])
        // Looks from before the browser was known don't count against it.
        #expect(k.kind(of: 1) == .unknown && k.wait(for: 1) == 0)
        for _ in 1...looks {
            #expect(k.kind(of: 1) == .unknown)
            k.saw([1: appWindow])
        }
        #expect(k.kind(of: 1) == .notBrowser)
    }

    @Test func anEventStartsAWindowsLooksOver() {
        var k = WindowKinds()
        k.saw([1: normal])
        for _ in 1...looks { k.saw([2: popup]) }
        #expect(k.kind(of: 2) == .notBrowser)
        k.startOver(2)
        #expect(k.kind(of: 2) == .unknown)
        k.saw([2: popup])
        #expect(k.wait(for: 2) == WindowKinds.waits[0])
        // A window that was only slow: its tabs are there at a later look.
        k.saw([2: normal])
        #expect(k.kind(of: 2) == .browser)
        // Starting over never takes back what was seen.
        k.startOver(2)
        #expect(k.kind(of: 2) == .browser)
    }

    @Test func closedWindowsAreForgottenAndWhatTheBrowserShowedIsNot() {
        var k = WindowKinds()
        k.saw([1: normal])
        for _ in 1...looks { k.saw([2: popup]) }
        k.keep([2])
        #expect(k.readable)
        #expect(!k.sawTabs(in: 1))
        #expect(k.kind(of: 2) == .notBrowser)
        k.keep([])
        #expect(k.kind(of: 2) == .unknown)
    }
}
