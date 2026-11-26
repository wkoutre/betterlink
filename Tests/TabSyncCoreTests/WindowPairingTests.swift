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

    /// One look at `time` (seconds). `others`: where the browser's windows that
    /// Accessibility doesn't list are (on a Space that isn't showing).
    private func look(_ p: inout WindowPairing, _ time: Double, _ windows: [WindowPairing.Window], others: [Double] = [],
                      _ entries: [SnapshotWindow]) -> [Int: WindowPairing.Found] {
        p.update(windows, others: [7: others.map { WindowBounds(left: $0, top: 31, width: 748, height: 1259) }], in: [session("/a", entries)], now: time)
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

    @Test func theFocusPairsAWindowOnceItsTitleNoLongerSaysNo() {
        var p = WindowPairing()
        let windows = [ours(100, "Docs", focused: true)]
        #expect(look(&p, 0, windows, [theirs(1, "Loading", focused: true), theirs(2, "Other")]) == [100: .waiting])
        #expect(look(&p, 0.3, windows, [theirs(1, "Loading", focused: true), theirs(2, "Other")]) == [100: .waiting])
        #expect(look(&p, 0.4, windows, [theirs(1, "Docs", focused: true), theirs(2, "Other")]) == [100: hit("/a", 1)])
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

    // MARK: - Every window of the browser, listed or not (the window server's list)

    /// A window of a profile without the extension, alone at its frame as far
    /// as Accessibility goes. Profile A's only window is at the same frame on
    /// a Space that isn't showing: the window server has it.
    @Test func aWindowIsNotPairedWhileAnUnlistedWindowOfTheBrowserCouldBeTheOne() {
        var p = WindowPairing()
        #expect(look(&p, 0, [ours(100, "Inbox - Google Chrome - Personal")], others: [0], [theirs(1, "Inbox")]) == [100: .unseen])
        // Paired first, the other window opening afterwards: let go.
        var q = WindowPairing()
        #expect(look(&q, 0, [ours(100, "Inbox")], [theirs(1, "Inbox")]) == [100: hit("/a", 1)])
        #expect(look(&q, 1, [ours(100, "Inbox")], others: [0], [theirs(1, "Inbox")]) == [100: .unseen])
        // Somewhere else, it is no rival.
        var r = WindowPairing()
        #expect(look(&r, 0, [ours(100, "Inbox")], others: [900], [theirs(1, "Inbox")]) == [100: hit("/a", 1)])
    }

    /// The focused window 100 and window 101 (no extension) share a frame and
    /// a title; the browser reports windows 1 (focused) and 2, and 2 is on a
    /// Space that isn't showing. What is left is not 101's.
    @Test func whatIsLeftIsNotConcludedWhileAnUnlistedWindowIsThere() {
        var p = WindowPairing()
        let windows = [ours(100, "New Tab", focused: true), ours(101, "New Tab")], entries = [theirs(1, "New Tab", focused: true), theirs(2, "New Tab")]
        _ = look(&p, 0, windows, others: [0], entries)
        #expect(look(&p, 0.31, windows, others: [0], entries) == [100: hit("/a", 1), 101: .unseen])
        // With every window of the browser listed and reported, it is.
        var q = WindowPairing()
        _ = look(&q, 0, windows, entries)
        #expect(look(&q, 0.31, windows, entries) == [100: hit("/a", 1), 101: hit("/a", 2)])
    }

    /// Windows on other Spaces that the browser reports cast no doubt: at that
    /// place there are as many browser windows reported as windows.
    @Test func unlistedWindowsTheBrowserReportsBlankNothing() {
        var p = WindowPairing()
        #expect(look(&p, 0, [ours(100, "Inbox")], others: [0, 0], [theirs(1, "Inbox"), theirs(2, "Docs"), theirs(3, "Mail")]) == [100: hit("/a", 1)])
        // One more window there than the browser reports: one of them isn't its.
        #expect(look(&p, 1, [ours(100, "Inbox")], others: [0, 0, 0], [theirs(1, "Inbox"), theirs(2, "Docs"), theirs(3, "Mail")]) == [100: .unseen])
    }

    /// A window that has moved on, while its browser window's frame is still
    /// to be reported: the unlisted window at the old place has its own.
    @Test func aMoveNextToAnUnlistedWindowBlanksNothing() {
        var p = WindowPairing()
        let entries = [theirs(1, "Inbox"), theirs(2, "Docs")]
        #expect(look(&p, 0, [ours(100, "Inbox")], others: [0], entries) == [100: hit("/a", 1)])
        #expect(look(&p, 1, [ours(100, "Inbox", at: 280)], others: [0], entries) == [100: hit("/a", 1)])
        #expect(look(&p, 2, [ours(100, "Inbox", at: 280)], others: [0], [theirs(1, "Inbox", at: 280), theirs(2, "Docs")]) == [100: hit("/a", 1)])
    }

    // MARK: - A word on the focus that is late by more than the moment

    /// 101 is window 1; 102 has no entry and looks like it. The focus moves
    /// from 101 to 102, and the browser's word that window 1 lost it is more
    /// than a moment late: 102 is paired by the focus. That is wrong for as
    /// long as they look alike, and no longer than `patience` once they don't.
    @Test func aPairingTheFocusMadeFromALateWordDoesNotOutliveItsLook() {
        var p = WindowPairing()
        let onOne = [theirs(1, "New Tab", focused: true)]
        _ = look(&p, 0, [ours(101, "New Tab", focused: true), ours(102, "New Tab")], onOne)
        #expect(look(&p, 0.3, [ours(101, "New Tab", focused: true), ours(102, "New Tab")], onOne) == [101: hit("/a", 1), 102: .unseen])
        let moved = [ours(101, "New Tab"), ours(102, "New Tab", focused: true)]
        _ = look(&p, 1, moved, onOne)
        _ = look(&p, 1.4, moved, onOne) // the late word still not in: 102 has entry 1 now
        _ = look(&p, 2, moved, [theirs(1, "New Tab")])
        // Window 1 goes to another page; 102 stays where it was.
        let apart = [ours(101, "Docs"), ours(102, "New Tab", focused: true)]
        _ = look(&p, 3, apart, [theirs(1, "Docs")])
        #expect(p.settlesAt.map { $0 <= 3 + WindowPairing.patience } ?? true)
        #expect(look(&p, 3 + WindowPairing.patience, apart, [theirs(1, "Docs")])[102] != hit("/a", 1))
        #expect(look(&p, 10, apart, [theirs(1, "Docs")])[102] != hit("/a", 1))
    }

    /// The window's new title is here at once, the browser's a look or two
    /// later (two seconds, with another app in front): what the focus paired
    /// stays, look-alike beside it or not.
    @Test func aNewTitleDoesNotBlankWhatTheFocusPaired() {
        var p = WindowPairing()
        let windows = [ours(101, "New Tab", focused: true), ours(102, "New Tab")]
        _ = look(&p, 0, windows, [theirs(1, "New Tab", focused: true)])
        _ = look(&p, 0.3, windows, [theirs(1, "New Tab", focused: true)])
        let paired = [101: hit("/a", 1), 102: WindowPairing.Found.unseen]
        let navigated = [ours(101, "Docs", focused: true), ours(102, "New Tab")]
        #expect(look(&p, 1, navigated, [theirs(1, "New Tab", focused: true)]) == paired)
        #expect(look(&p, 2, navigated, [theirs(1, "New Tab")]) == paired) // another app in front, a second look
        #expect(look(&p, 3, navigated, [theirs(1, "Docs")]) == paired)
        #expect(look(&p, 9, navigated, [theirs(1, "Docs")]) == paired)
    }

    /// The focus never pairs against a title that says no.
    @Test func theFocusDoesNotOverrideATitleThatSaysNo() {
        var p = WindowPairing()
        let windows = [ours(100, "Secret - Google Chrome (Incognito)", focused: true)], entries = [theirs(1, "Inbox", focused: true)]
        _ = look(&p, 0, windows, entries)
        #expect(look(&p, 0.3, windows, entries)[100] != hit("/a", 1))
        #expect(look(&p, 5, windows, entries)[100] != hit("/a", 1))
    }

    // MARK: - The window server's list

    /// Read from a Mac with Chrome running one window (2026-11-25): the list
    /// also holds strips the height of the menu bar, bubbles, 1 pt and 64 pt
    /// helper windows at the standard layer, and windows at other layers.
    @Test func onlyWindowsThatCouldBeABrowserWindowCountAsUnlisted() {
        func w(_ number: UInt32, _ layer: Int, _ x: Double, _ y: Double, _ width: Double, _ height: Double, pid: Int = 61068) -> WindowPairing.ServerWindow {
            .init(number: number, pid: pid, layer: layer, bounds: WindowBounds(left: x, top: y, width: width, height: height))
        }
        let chrome = [w(48506, 0, 0, 0, 2056, 30), w(48505, 0, 0, 0, 2056, 30), w(47295, 0, 207, 16, 1089, 89), w(47136, 0, 1016, 63, 403, 84),
                      w(45745, 1000, 344, 208, 116, 56), w(45728, 0, 0, 0, 1, 1), w(45727, 0, 0, 31, 2056, 1259), w(38736, 103, 1609, 436, 49, 18),
                      w(38738, 0, 0, 790, 64, 64), w(48131, 0, 0, 31, 2056, 1259, pid: 96713), w(48510, 0, 0, 0, 2056, 30, pid: 96713)]
        let main = WindowBounds(left: 0, top: 31, width: 2056, height: 1259)
        // Its one window followed: nothing else of Chrome's could be a browser window.
        #expect(WindowPairing.unlisted(chrome, followed: [45727]) == [96713: [main]])
        #expect(WindowPairing.unlisted(chrome, followed: []) == [61068: [main], 96713: [main]])
        // A small window that isn't a strip counts: too many only blanks a sidebar.
        #expect(WindowPairing.unlisted([w(1, 0, 10, 10, 320, 240)], followed: []) == [61068: [WindowBounds(left: 10, top: 10, width: 320, height: 240)]])
    }
}
