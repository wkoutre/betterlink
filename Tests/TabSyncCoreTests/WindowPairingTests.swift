import Foundation
import Testing
@testable import TabSyncCore

struct WindowPairingTests {
    private func snapshot(_ wins: [SnapshotWindow]) -> Inbound {
        var m = Inbound(type: "snapshot"); m.seq = 1; m.windows = wins; return m
    }
    private func session(_ path: String, pid: Int = 7, _ wins: [SnapshotWindow]) -> BrowserSession {
        var s = BrowserSession(socketPath: path)
        s.browserPid = pid
        s.browser = "Google Chrome"
        s.store.apply(snapshot(wins))
        return s
    }
    private func theirs(_ id: Int, _ title: String, at left: Double = 0, focused: Bool = false) -> SnapshotWindow {
        SnapshotWindow(id: id, focused: focused, tabs: [Tab(id: id * 10, windowId: id, title: title, active: true)],
                       left: left, top: 31, width: 748, height: 1259)
    }
    private func ours(_ id: Int, _ title: String, at left: Double = 0, focused: Bool = false, pid: Int = 7) -> WindowPairing.Window {
        .init(id: id, pid: pid, app: "Google Chrome", frame: WindowBounds(left: left, top: 31, width: 748, height: 1259),
              title: title, focused: focused)
    }
    private func hit(_ s: String, _ w: Int) -> WindowPairing.Found { .window(.init(session: s, windowId: w)) }

    /// One look at `time` (seconds).
    private func look(_ p: inout WindowPairing, _ time: Double, _ windows: [WindowPairing.Window], _ entries: [SnapshotWindow]) -> [Int: WindowPairing.Found] {
        p.update(windows, in: [session("/a", entries)], now: time)
    }

    // MARK: - By frame and title

    @Test func eachWindowOfTwoProfilesInOneProcessGetsItsOwn() {
        let work = session("/work", [theirs(1, "Tracker")]), personal = session("/personal", [theirs(9, "Inbox", at: 1800, focused: true)])
        var p = WindowPairing()
        let found = p.update([ours(100, "Tracker - Google Chrome - Work"), ours(101, "Inbox - Google Chrome", at: 1801, focused: true)],
                             in: [work, personal], now: 0)
        #expect(found == [100: hit("/work", 1), 101: hit("/personal", 9)])
    }

    @Test func sameFrameIsToldApartByTitle() {
        var p = WindowPairing()
        #expect(look(&p, 0, [ours(100, "Docs - Chrome"), ours(101, "Inbox - Chrome")], [theirs(1, "Inbox"), theirs(2, "Docs")]) == [100: hit("/a", 2), 101: hit("/a", 1)])
    }

    @Test func sameTitleIsToldApartByFrame() {
        var p = WindowPairing()
        #expect(look(&p, 0, [ours(100, "New Tab", at: 900), ours(101, "New Tab")], [theirs(1, "New Tab"), theirs(2, "New Tab", at: 900)]) == [100: hit("/a", 2), 101: hit("/a", 1)])
    }

    @Test func sameFrameAndTitleIsNeverGuessed() {
        var p = WindowPairing()
        let entries = [theirs(1, "New Tab"), theirs(2, "New Tab")]
        #expect(look(&p, 0, [ours(100, "New Tab"), ours(101, "New Tab")], entries) == [100: .unseen, 101: .unseen])
        // Only one is known here: which one can't be told either.
        #expect(look(&p, 1, [ours(100, "New Tab")], entries) == [100: .unseen])
    }

    // MARK: - Out of step (5)

    @Test func aCertainPairingStaysThroughMovesTitlesAndAStaleFocus() {
        var p = WindowPairing()
        _ = look(&p, 0, [ours(100, "Inbox", focused: true), ours(101, "Docs", at: 900)], [theirs(1, "Inbox", focused: true), theirs(2, "Docs", at: 900)])
        // Both now show the same page in the same place, and the browser hasn't
        // said yet that the other window has the focus.
        let found = look(&p, 1, [ours(100, "New Tab"), ours(101, "New Tab", focused: true)], [theirs(1, "New Tab", focused: true), theirs(2, "New Tab")])
        #expect(found == [100: hit("/a", 1), 101: hit("/a", 2)])
    }

    /// The window's title and frame are here at once, the browser's a moment
    /// (or two seconds) later: the tabs stay.
    @Test func beingOutOfStepBlanksNothing() {
        var p = WindowPairing()
        let paired = [100: hit("/a", 1)]
        #expect(look(&p, 0, [ours(100, "Inbox")], [theirs(1, "Inbox")]) == paired)
        #expect(look(&p, 1, [ours(100, "Docs")], [theirs(1, "Inbox")]) == paired)          // a new title
        #expect(look(&p, 2, [ours(100, "Docs")], [theirs(1, "Docs")]) == paired)
        #expect(look(&p, 3, [ours(100, "Docs", at: 900)], [theirs(1, "Docs")]) == paired)  // moved
        #expect(look(&p, 4, [ours(100, "Docs", at: 900)], [theirs(1, "Docs", at: 900)]) == paired)
        // With another window of the browser at the same place the whole time.
        var q = WindowPairing()
        let two = [100: hit("/a", 1), 101: hit("/a", 2)]
        #expect(look(&q, 0, [ours(100, "Inbox"), ours(101, "Docs")], [theirs(1, "Inbox"), theirs(2, "Docs")]) == two)
        #expect(look(&q, 1, [ours(100, "Mail"), ours(101, "Docs")], [theirs(1, "Inbox"), theirs(2, "Docs")]) == two)
        #expect(look(&q, 2, [ours(100, "Mail"), ours(101, "Docs")], [theirs(1, "Mail"), theirs(2, "Docs")]) == two)
    }

    // MARK: - The focus (3, 4)

    @Test func theFocusCountsOnceItHasHeldAndTheOtherIsWhatIsLeft() {
        var p = WindowPairing()
        let windows = [ours(100, "New Tab"), ours(101, "New Tab", focused: true)], entries = [theirs(1, "New Tab", focused: true), theirs(2, "New Tab")]
        // A word on the focus, heard once: nothing yet, and a look due a moment on.
        #expect(look(&p, 5, windows, entries) == [100: .waiting, 101: .waiting])
        #expect(p.settlesAt == 5 + WindowPairing.moment)
        #expect(look(&p, 5.1, windows, entries) == [100: .waiting, 101: .waiting])
        #expect(look(&p, 5.3, windows, entries) == [100: hit("/a", 2), 101: hit("/a", 1)])
        #expect(p.settlesAt == nil)
    }

    /// The browser goes to the back (it then reports no focused window), comes
    /// forward again, and a look-alike with no entry sits beside it throughout.
    @Test func whatTheFocusPairedStaysThroughAppSwitchesAndLookAlikes() {
        var p = WindowPairing()
        let front = [ours(100, "New Tab", focused: true), ours(102, "New Tab")], held = [100: hit("/a", 1), 102: WindowPairing.Found.unseen]
        _ = look(&p, 0, front, [theirs(1, "New Tab", focused: true)])
        #expect(look(&p, 0.3, front, [theirs(1, "New Tab", focused: true)]) == held)
        #expect(look(&p, 1, front, [theirs(1, "New Tab")]) == held)                      // another app in front
        #expect(look(&p, 2, front, [theirs(1, "New Tab", focused: true)]) == held)       // back: nothing to wait for
        #expect(p.settlesAt == nil)
    }

    @Test func theFocusPairsAWindowWhoseTitleHasNotArrived() {
        var p = WindowPairing()
        let windows = [ours(100, "Docs", focused: true)], entries = [theirs(1, "Loading", focused: true), theirs(2, "Other")]
        #expect(look(&p, 0, windows, entries) == [100: .waiting])
        #expect(look(&p, 0.3, windows, entries) == [100: hit("/a", 1)])
    }

    @Test func theFocusIsNotTakenWhenBothTitleAndFrameSayOtherwise() {
        var p = WindowPairing()
        let windows = [ours(101, "Secret (Incognito)", at: 900, focused: true)], entries = [theirs(1, "Inbox", focused: true)]
        #expect(look(&p, 0, windows, entries) == [101: .unseen])
        #expect(look(&p, 1, windows, entries) == [101: .unseen])
    }

    // MARK: - A pairing that was a coincidence
    //
    // The windows known here are never all there are: Accessibility lists only
    // those on a Space that is showing, and a profile without the extension or
    // an Incognito window is in no session. So "each matches no other" can be
    // true of a window and a browser window that are not the same one.

    /// Profile B has no extension; its window sits where profile A's window
    /// 1, on a Space not shown yet, also is, with the same title.
    @Test func aCoincidenceGivesWayWhenTheRealWindowIsListed() {
        var p = WindowPairing()
        #expect(look(&p, 0, [ours(100, "New Tab")], [theirs(1, "New Tab")]) == [100: hit("/a", 1)])
        // Window 1 itself is listed now, and has the focus in both accounts.
        let both = [ours(100, "New Tab"), ours(101, "New Tab", focused: true)], entries = [theirs(1, "New Tab", focused: true)]
        #expect(look(&p, 1, both, entries) == [100: .waiting, 101: .waiting])
        #expect(look(&p, 1.3, both, entries) == [100: .unseen, 101: hit("/a", 1)])
        #expect(look(&p, 2, [ours(100, "New Tab"), ours(101, "Docs", focused: true)], [theirs(1, "Docs", focused: true)]) == [100: .unseen, 101: hit("/a", 1)])
    }

    @Test func withoutTheFocusNeitherIsShownUntilSomethingTellsThemApart() {
        var p = WindowPairing()
        _ = look(&p, 0, [ours(100, "New Tab")], [theirs(1, "New Tab")])
        #expect(look(&p, 1, [ours(100, "New Tab"), ours(101, "New Tab")], [theirs(1, "New Tab")]) == [100: .unseen, 101: .unseen])
        #expect(look(&p, 2, [ours(100, "New Tab"), ours(101, "Docs")], [theirs(1, "Docs")]) == [100: .unseen, 101: hit("/a", 1)])
    }

    /// A new window is announced before the browser reports it, at the frame
    /// and title of a window on a Space not shown since launch.
    @Test func aWindowPairedBeforeItsOwnEntryArrivesEndsWithItsOwn() {
        for focusKnown in [true, false] {
            var p = WindowPairing()
            #expect(look(&p, 0, [ours(100, "New Tab", focused: true)], [theirs(1, "New Tab")]) == [100: hit("/a", 1)])
            // Its own entry is in: two it could be now, and only the focus says which.
            let entries = [theirs(1, "New Tab"), theirs(2, "New Tab", focused: focusKnown)]
            #expect(look(&p, 1, [ours(100, "New Tab", focused: true)], entries) == [100: focusKnown ? .waiting : .unseen])
            #expect(look(&p, 1.3, [ours(100, "New Tab", focused: true)], entries) == [100: focusKnown ? hit("/a", 2) : .unseen])
            // Only its title changes (it stays where it is), or its frame too.
            for left in [0.0, 900] {
                var q = p
                let moved = look(&q, 2, [ours(100, "Docs", at: left, focused: true)], [theirs(1, "New Tab"), theirs(2, "Docs", at: left, focused: focusKnown)])
                #expect(moved == [100: hit("/a", 2)])
            }
        }
    }

    /// With no word of the new entry in between: the old one stops matching
    /// while another does.
    @Test func aPairingMovesToTheEntryThatMatchesWhenItsOwnNoLongerDoes() {
        var p = WindowPairing()
        _ = look(&p, 0, [ours(100, "New Tab")], [theirs(1, "New Tab")])
        #expect(look(&p, 1, [ours(100, "Docs")], [theirs(1, "New Tab"), theirs(2, "Docs")]) == [100: hit("/a", 2)])
    }

    @Test func aNewcomerLikeAPairedWindowPutsItInDoubtUntilTheFocusOrATitleSays() {
        var p = WindowPairing()
        _ = look(&p, 0, [ours(100, "Inbox")], [theirs(1, "Inbox")])
        // An Incognito window the extension can't see, on top of it, at the same page.
        #expect(look(&p, 1, [ours(100, "Inbox"), ours(102, "Inbox")], [theirs(1, "Inbox")]) == [100: .unseen, 102: .unseen])
        var q = p
        #expect(look(&q, 2, [ours(100, "Inbox"), ours(102, "Secret")], [theirs(1, "Inbox")]) == [100: hit("/a", 1), 102: .unseen])
        let focused = [ours(100, "Inbox", focused: true), ours(102, "Inbox")]
        _ = look(&p, 2, focused, [theirs(1, "Inbox", focused: true)])
        #expect(look(&p, 2.3, focused, [theirs(1, "Inbox", focused: true)]) == [100: hit("/a", 1), 102: .unseen])
    }

    // MARK: - Windows the extension doesn't report, titles and frames that aren't there

    @Test func anIncognitoWindowTheExtensionCannotSeeShowsNoOtherWindowsTabs() {
        var p = WindowPairing()
        #expect(look(&p, 0, [ours(100, "Secret - Google Chrome (Incognito)")], [theirs(1, "Inbox")]) == [100: .unseen])
        // On top of the regular window, untitled so far: that one is taken.
        #expect(look(&p, 1, [ours(100, ""), ours(101, "Inbox - Google Chrome")], [theirs(1, "Inbox")]) == [100: .unseen, 101: hit("/a", 1)])
    }

    @Test func aPageStillLoadingIsMatchedByItsFrameAlone() {
        for title in ["Untitled - Google Chrome", ""] {
            var p = WindowPairing()
            #expect(look(&p, 0, [ours(100, title)], [theirs(1, ""), theirs(2, "Docs", at: 800)]) == [100: hit("/a", 1)])
        }
    }

    @Test func aWindowPairedByItsFrameAloneIsLetGoWhenItsTitleSaysOtherwise() {
        // An Incognito window the extension can't see, exactly on a regular
        // window that isn't followed yet (another Space), untitled so far.
        var p = WindowPairing()
        #expect(look(&p, 0, [ours(100, "")], [theirs(1, "Inbox")]) == [100: hit("/a", 1)])
        #expect(look(&p, 1, [ours(100, "Secret - Google Chrome (Incognito)")], [theirs(1, "Inbox")]) == [100: .unseen])
        // One whose title then agrees is kept, through a later title too.
        _ = look(&p, 2, [ours(101, "")], [theirs(1, "Inbox")])
        #expect(look(&p, 3, [ours(101, "Inbox - Google Chrome")], [theirs(1, "Inbox")]) == [101: hit("/a", 1)])
        #expect(look(&p, 4, [ours(101, "Docs - Google Chrome")], [theirs(1, "Inbox")]) == [101: hit("/a", 1)])
    }

    @Test func withoutFramesTheTitleAloneDecidesWhenOneWindowHasIt() {
        func frameless(_ id: Int, _ title: String) -> SnapshotWindow {
            SnapshotWindow(id: id, focused: false, tabs: [Tab(id: id * 10, windowId: id, title: title, active: true)])
        }
        var p = WindowPairing()
        #expect(look(&p, 0, [ours(100, "Docs - Brave"), ours(101, "Neither")], [frameless(1, "Inbox"), frameless(2, "Docs")]) == [100: hit("/a", 2), 101: .unseen])
    }

    @Test func aClosedWindowFreesItsIdAndAReusedIdIsMatchedAfresh() {
        var p = WindowPairing()
        _ = look(&p, 0, [ours(100, "Inbox")], [theirs(1, "Inbox")])
        // The browser window is gone: so is the pairing.
        #expect(look(&p, 1, [ours(100, "Inbox")], [theirs(2, "Docs", at: 900)]) == [100: .unseen])
        _ = look(&p, 2, [ours(100, "Inbox")], [theirs(1, "Inbox")])
        // Ours is gone and another has come; the browser gave the new one the old id.
        #expect(look(&p, 3, [ours(105, "Docs", at: 900)], [theirs(1, "Docs", at: 900)]) == [105: hit("/a", 1)])
    }

    @Test func twoBrowsersWithTheSameWindowIdsStayApart() {
        var p = WindowPairing()
        let chrome = session("/chrome", [theirs(1, "Inbox")]), brave = session("/brave", pid: 8, [theirs(1, "Inbox")])
        #expect(p.update([ours(100, "Inbox"), ours(200, "Inbox", pid: 8)], in: [chrome, brave], now: 0) == [100: hit("/chrome", 1), 200: hit("/brave", 1)])
    }

    @Test func aSessionWhoseProcessIsNotKnownIsFoundByTheBrowsersName() {
        var p = WindowPairing()
        #expect(p.update([ours(100, "Inbox")], in: [session("/a", pid: 0, [theirs(1, "Inbox")])], now: 0) == [100: hit("/a", 1)])
    }

    @Test func aBrowserWithNoExtensionConnectedIsNotConnected() {
        var p = WindowPairing()
        #expect(p.update([ours(100, "Inbox")], in: [], now: 0) == [100: .notConnected])
    }

    // MARK: - The second review's cases (2, 4)

    @Test func aPairIsNeverKeptOnceTitleAndFrameBothSayOtherwise() {
        var p = WindowPairing()
        #expect(look(&p, 0, [ours(100, "New Tab")], [theirs(1, "New Tab")]) == [100: hit("/a", 1)])
        // Window 1 itself isn't listed; the one that looked like it no longer does.
        #expect(look(&p, 1, [ours(100, "New Tab")], [theirs(1, "Docs", at: 900)]) == [100: .unseen])
    }

    /// 102 belongs to a profile without the extension. It takes the focus, and
    /// the browser's word that window 1 lost it is still on its way.
    @Test func aStaleWordOnTheFocusNeverHandsAnEntryToALookAlike() {
        var p = WindowPairing()
        _ = look(&p, 0, [ours(100, "New Tab")], [theirs(1, "New Tab")])
        let stale = [theirs(1, "New Tab", focused: true)], current = [theirs(1, "New Tab")]
        let windows = [ours(100, "New Tab"), ours(102, "New Tab", focused: true)]
        for (time, entries) in [(1.0, stale), (1.05, current), (1.5, current), (3, current)] {
            let found = look(&p, time, windows, entries)
            #expect(found[102] != hit("/a", 1))
            #expect(found[100] != hit("/a", 2))
        }
    }

    /// The same from a pairing the focus made.
    @Test func aStaleWordOnTheFocusTakesNothingFromTheWindowTheFocusPaired() {
        var p = WindowPairing()
        let first = [ours(100, "New Tab", focused: true), ours(102, "New Tab")], second = [ours(100, "New Tab"), ours(102, "New Tab", focused: true)]
        let onOne = [theirs(1, "New Tab", focused: true)], onNone = [theirs(1, "New Tab")]
        var found: [Int: WindowPairing.Found] = [:]
        for (time, windows, entries) in [(0.0, first, onOne), (0.4, first, onOne), (1, second, onOne), (1.05, second, onNone), (1.5, second, onNone)] {
            found = look(&p, time, windows, entries)
            #expect(found[102] != hit("/a", 1))
        }
        #expect(found[100] == hit("/a", 1))
    }

    /// 100 has entry 1. A new window 101 opens at the same place on the same
    /// page and the browser reports it (entry 2) with the focus. Then macOS
    /// says 100 has the focus before the browser says so.
    @Test func aStaleWordOnTheFocusNeverSwapsTwoLookAlikes() {
        for settledFirst in [true, false] { // the new window's focus held before the next, or not
            var p = WindowPairing()
            _ = look(&p, 0, [ours(100, "New Tab")], [theirs(1, "New Tab")])
            let new = [ours(100, "New Tab"), ours(101, "New Tab", focused: true)], back = [ours(100, "New Tab", focused: true), ours(101, "New Tab")]
            let onTwo = [theirs(1, "New Tab"), theirs(2, "New Tab", focused: true)], onOne = [theirs(1, "New Tab", focused: true), theirs(2, "New Tab")]
            var steps: [(Double, [WindowPairing.Window], [SnapshotWindow])] = [(1, new, onTwo)]
            if settledFirst { steps.append((1.4, new, onTwo)) }
            steps += [(2, back, onTwo), (2.05, back, onOne), (2.5, back, onOne)]
            var found: [Int: WindowPairing.Found] = [:]
            for (time, windows, entries) in steps {
                found = look(&p, time, windows, entries)
                #expect(found[100] != hit("/a", 2))
                #expect(found[101] != hit("/a", 1))
            }
            #expect(found == [100: hit("/a", 1), 101: hit("/a", 2)])
        }
    }
}
