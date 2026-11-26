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

    /// Live, 2026-11-25, a popup and an app window open: every event that
    /// listed the windows again gave both their six looks afresh, twelve
    /// walks for a switch between two normal windows. A window that has been
    /// judged keeps that until an event names that very window.
    @Test func aWindowThatHasBeenJudgedIsNotLookedAtAgainForBeingListed() {
        var k = WindowKinds()
        #expect(k.needsLook(1))
        k.saw([1: normal])
        // Seen with tabs: never read again.
        #expect(!k.needsLook(1))
        // New, or with looks still to come.
        #expect(k.needsLook(2))
        k.saw([2: popup])
        #expect(k.needsLook(2))
        for _ in 2...looks { k.saw([2: popup]) }
        #expect(k.kind(of: 2) == .notBrowser && !k.needsLook(2))
        // It gets the focus: named, it gets its looks afresh.
        k.startOver(2)
        #expect(k.needsLook(2))
        // In a browser never seen with tabs (Dia) a new window is read, to
        // learn whether the browser shows them after all.
        var d = WindowKinds()
        d.saw([1: dia])
        #expect(d.needsLook(1) && d.needsLook(2))
        #expect(!d.isNew(1) && d.isNew(2))
    }

    @Test func aWindowSeenToCloseIsForgottenThen() {
        var k = WindowKinds()
        k.saw([1: normal, 3: normal])
        for _ in 1...looks { k.saw([2: popup]) }
        #expect(!k.isNew(2))
        k.forget(2)
        #expect(k.isNew(2))
        #expect(k.kind(of: 2) == .unknown && k.needsLook(2))
        k.forget(1)
        #expect(!k.sawTabs(in: 1))
        // What the browser showed stays, and so do its other windows.
        #expect(k.readable && k.sawTabs(in: 3))
    }

    // MARK: - The browser's own word, through the extension

    @Test func aWindowTheExtensionCallsNormalIsABrowserWindowWhateverItShows() {
        var k = WindowKinds()
        k.saw([1: normal])
        for _ in 1...looks { k.saw([2: R(tabGroups: 0, tabs: 0)]) }
        #expect(k.kind(of: 2) == .notBrowser)
        k.said([2: .normal])
        #expect(k.kind(of: 2) == .browser)
        // And at once, before any look.
        k.said([3: .normal])
        #expect(k.kind(of: 3) == .browser)
    }

    /// A native tab view reads as a tab group with tabs too. Should one of
    /// Dia's windows ever show one (a settings window, a sheet), Dia's real
    /// windows, which show none, must not lose their sidebars for it.
    @Test func aBrowserWhereANormalWindowShowsNoTabsIsNotOneTabsCanTell() {
        var k = WindowKinds()
        k.saw([1: dia, 2: dia])
        k.said([1: .normal])
        k.saw([9: R(tabGroups: 1, tabs: 3)])
        // For now it looks like a browser that shows its tabs.
        #expect(k.readable)
        #expect(k.kind(of: 1) == .browser)
        #expect(k.kind(of: 2) == .unknown)
        // The window the extension calls normal gets its looks like any other.
        for look in 1...looks {
            #expect(k.wait(for: 1) != nil, "before look \(look)")
            #expect(k.kind(of: 1) == .browser)
            k.saw([1: dia, 2: dia])
        }
        // It showed none: tabs don't tell this browser's windows apart.
        #expect(!k.readable)
        #expect(k.kind(of: 1) == .browser && k.kind(of: 2) == .browser)
        #expect(k.wait(for: 1) == nil && k.wait(for: 2) == nil)
        // And the window with the tab view can't say otherwise again.
        k.saw([9: R(tabGroups: 1, tabs: 3)])
        #expect(!k.readable && k.kind(of: 2) == .browser)
    }

    @Test func theSameHoldsWhenTheWordComesAfterTheLooks() {
        var k = WindowKinds()
        k.saw([9: R(tabGroups: 1, tabs: 3)])
        for _ in 1...looks { k.saw([1: dia, 2: dia]) }
        #expect(k.kind(of: 1) == .notBrowser && k.kind(of: 2) == .notBrowser)
        k.said([1: .normal])
        #expect(!k.readable)
        #expect(k.kind(of: 1) == .browser && k.kind(of: 2) == .browser)
    }

    /// Dia with the extension: the palette is a popup to the browser, and
    /// that is all there is to tell it by.
    @Test func aWindowTheExtensionCallsAPopupIsNotABrowserWindow() {
        var k = WindowKinds()
        k.saw([1: dia, 2: dia])
        #expect(k.kind(of: 1) == .browser && k.kind(of: 2) == .browser)
        k.said([1: .normal, 2: .other])
        #expect(k.kind(of: 1) == .browser)
        #expect(k.kind(of: 2) == .notBrowser)
        // With no sidebar it is no longer paired: the word it was given stays.
        k.said([1: .normal])
        #expect(k.kind(of: 2) == .notBrowser)
        // A later word replaces an earlier one.
        k.said([2: .normal])
        #expect(k.kind(of: 2) == .browser)
        // Tabs seen in the window itself outweigh a pairing that says popup.
        var c = WindowKinds()
        c.saw([3: normal])
        c.said([3: .other])
        #expect(c.kind(of: 3) == .browser)
        // In a browser that shows its tabs, a popup's word only confirms.
        c.saw([4: popup])
        c.said([4: .other])
        #expect(c.kind(of: 4) == .notBrowser && c.wait(for: 4) == nil)
    }

    @Test func whereTabsCantTellANewWindowWaitsForTheExtensionsWordWhileItIsConnected() {
        var k = WindowKinds()
        k.listening = true
        k.saw([1: dia])
        #expect(k.kind(of: 1) == .unknown && k.awaitsWord(1))
        // Waiting for a word is not looking again.
        #expect(k.wait(for: 1) == nil)
        k.said([1: .other])
        #expect(k.kind(of: 1) == .notBrowser && !k.awaitsWord(1))
        // No word in time: a browser window, as before. A late word still counts.
        k.saw([2: dia])
        k.waited(2)
        #expect(k.kind(of: 2) == .browser && !k.awaitsWord(2))
        k.said([2: .other])
        #expect(k.kind(of: 2) == .notBrowser)
        // A browser started with only an app window, the extension connected:
        // the window never counts as a browser window.
        var a = WindowKinds()
        a.listening = true
        a.saw([1: appWindow])
        #expect(a.kind(of: 1) == .unknown)
        a.said([1: .other])
        #expect(a.kind(of: 1) == .notBrowser)
        // Without the extension nothing is waited for.
        var d = WindowKinds()
        d.saw([1: dia])
        #expect(d.kind(of: 1) == .browser && !d.awaitsWord(1))
        // Where tabs do tell, a look decides and no word is waited for.
        var c = WindowKinds()
        c.listening = true
        c.saw([1: normal])
        c.saw([2: popup])
        #expect(!c.awaitsWord(2) && c.kind(of: 2) == .unknown && c.wait(for: 2) == WindowKinds.waits[0])
    }

    /// A window that closes, by whichever path, leaves nothing behind: not
    /// the word it was given, nor that its wait for one was over.
    @Test func aClosedWindowLeavesNeitherItsWordNorItsWaitBehind() {
        var k = WindowKinds()
        k.listening = true
        k.saw([1: dia, 2: dia, 3: dia])
        k.said([1: .other])
        k.waited(2)
        #expect(k.kind(of: 1) == .notBrowser && k.kind(of: 2) == .browser && k.awaitsWord(3))
        // Seen to close (Accessibility, or a look that finds it gone).
        k.forget(1)
        k.forget(2)
        #expect(k.isNew(1) && k.isNew(2))
        #expect(k.kind(of: 1) == .unknown && k.awaitsWord(1) && k.awaitsWord(2))
        // Forgetting twice changes nothing more.
        let once = k
        k.forget(1)
        #expect(k == once)
        // The window server's list without it (a palette judged and never followed).
        k.said([3: .other])
        k.keep([])
        #expect(k.isNew(3) && k.listening)
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
