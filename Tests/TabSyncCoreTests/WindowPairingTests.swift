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

    @Test func eachWindowOfTwoProfilesInOneProcessGetsItsOwn() {
        let work = session("/work", [theirs(1, "Tracker")]), personal = session("/personal", [theirs(9, "Inbox", at: 1800, focused: true)])
        var p = WindowPairing()
        let found = p.update([ours(100, "Tracker - Google Chrome - Work"), ours(101, "Inbox - Google Chrome", at: 1801, focused: true)], in: [work, personal])
        #expect(found == [100: hit("/work", 1), 101: hit("/personal", 9)])
        #expect(p.isCertain(100) && p.isCertain(101))
    }

    @Test func aCertainPairingStaysThroughMovesTitlesAndAStaleFocus() {
        var p = WindowPairing()
        _ = p.update([ours(100, "Inbox", focused: true), ours(101, "Docs", at: 900)],
                     in: [session("/a", [theirs(1, "Inbox", focused: true), theirs(2, "Docs", at: 900)])])
        // Both now show the same page in the same place, and the browser hasn't
        // said yet that the other window has the focus.
        let found = p.update([ours(100, "New Tab"), ours(101, "New Tab", focused: true)],
                             in: [session("/a", [theirs(1, "New Tab", focused: true), theirs(2, "New Tab")])])
        #expect(found == [100: hit("/a", 1), 101: hit("/a", 2)])
    }

    // MARK: - A certain pairing that was a coincidence
    //
    // The windows known here are never all there are: Accessibility lists only
    // those on a Space that is showing, and a profile without the extension or
    // an Incognito window is in no session. So "each matches no other" can be
    // true of a window and a browser window that are not the same one.

    /// Profile B has no extension; its window sits where profile A's window
    /// 1, on a Space not shown yet, also is, with the same title.
    @Test func aCoincidenceGivesWayWhenTheRealWindowIsListed() {
        var p = WindowPairing()
        #expect(p.update([ours(100, "New Tab")], in: [session("/a", [theirs(1, "New Tab")])]) == [100: hit("/a", 1)])
        // Window 1 itself is listed now, and has the focus in both accounts.
        let both = p.update([ours(100, "New Tab"), ours(101, "New Tab", focused: true)], in: [session("/a", [theirs(1, "New Tab", focused: true)])])
        #expect(both == [100: .unseen, 101: hit("/a", 1)])
        let later = p.update([ours(100, "New Tab"), ours(101, "Docs", focused: true)], in: [session("/a", [theirs(1, "Docs", focused: true)])])
        #expect(later == [100: .unseen, 101: hit("/a", 1)])
        #expect(p.isCertain(101))
    }

    @Test func withoutTheFocusNeitherIsShownUntilSomethingTellsThemApart() {
        var p = WindowPairing()
        let s = session("/a", [theirs(1, "New Tab")])
        _ = p.update([ours(100, "New Tab")], in: [s])
        #expect(p.update([ours(100, "New Tab"), ours(101, "New Tab")], in: [s]) == [100: .unseen, 101: .unseen])
        #expect(p.update([ours(100, "New Tab"), ours(101, "Docs")], in: [session("/a", [theirs(1, "Docs")])]) == [100: .unseen, 101: hit("/a", 1)])
    }

    /// A new window is announced before the browser reports it, at the frame
    /// and title of a window on a Space not shown since launch.
    @Test func aWindowPairedBeforeItsOwnEntryArrivesEndsWithItsOwn() {
        for focusKnown in [true, false] {
            var p = WindowPairing()
            #expect(p.update([ours(100, "New Tab", focused: true)], in: [session("/a", [theirs(1, "New Tab")])]) == [100: hit("/a", 1)])
            // Its own entry is in: two it could be now, and only the focus says which.
            let arrived = p.update([ours(100, "New Tab", focused: true)],
                                   in: [session("/a", [theirs(1, "New Tab"), theirs(2, "New Tab", focused: focusKnown)])])
            #expect(arrived == [100: focusKnown ? hit("/a", 2) : .unseen])
            // Only its title changes (it stays where it is), or its frame too.
            for left in [0.0, 900] {
                var q = p
                let moved = q.update([ours(100, "Docs", at: left, focused: true)],
                                     in: [session("/a", [theirs(1, "New Tab"), theirs(2, "Docs", at: left, focused: focusKnown)])])
                #expect(moved == [100: hit("/a", 2)])
                #expect(q.isCertain(100))
            }
        }
    }

    /// With no word of the new entry in between: the old one stops matching
    /// while another does.
    @Test func aCertainPairingMovesToTheEntryThatMatchesWhenItsOwnNoLongerDoes() {
        var p = WindowPairing()
        _ = p.update([ours(100, "New Tab")], in: [session("/a", [theirs(1, "New Tab")])])
        let found = p.update([ours(100, "Docs")], in: [session("/a", [theirs(1, "New Tab"), theirs(2, "Docs")])])
        #expect(found == [100: hit("/a", 2)])
    }

    @Test func aNewcomerLikeACertainWindowPutsItInDoubtUntilTheFocusOrATitleSays() {
        var p = WindowPairing()
        _ = p.update([ours(100, "Inbox")], in: [session("/a", [theirs(1, "Inbox")])])
        // An Incognito window the extension can't see, on top of it, at the same page.
        #expect(p.update([ours(100, "Inbox"), ours(102, "Inbox")], in: [session("/a", [theirs(1, "Inbox")])]) == [100: .unseen, 102: .unseen])
        let focused = p.update([ours(100, "Inbox", focused: true), ours(102, "Inbox")], in: [session("/a", [theirs(1, "Inbox", focused: true)])])
        #expect(focused == [100: hit("/a", 1), 102: .unseen])
        let apart = p.update([ours(100, "Inbox"), ours(102, "Secret")], in: [session("/a", [theirs(1, "Inbox")])])
        #expect(apart == [100: hit("/a", 1), 102: .unseen])
        #expect(p.isCertain(100))
    }

    @Test func sameFrameIsToldApartByTitle() {
        var p = WindowPairing()
        let found = p.update([ours(100, "Docs - Chrome"), ours(101, "Inbox - Chrome")], in: [session("/a", [theirs(1, "Inbox"), theirs(2, "Docs")])])
        #expect(found == [100: hit("/a", 2), 101: hit("/a", 1)])
    }

    @Test func sameTitleIsToldApartByFrame() {
        var p = WindowPairing()
        let found = p.update([ours(100, "New Tab", at: 900), ours(101, "New Tab")], in: [session("/a", [theirs(1, "New Tab"), theirs(2, "New Tab", at: 900)])])
        #expect(found == [100: hit("/a", 2), 101: hit("/a", 1)])
    }

    @Test func sameFrameAndTitleIsNeverGuessed() {
        var p = WindowPairing()
        let s = session("/a", [theirs(1, "New Tab"), theirs(2, "New Tab")])
        #expect(p.update([ours(100, "New Tab"), ours(101, "New Tab")], in: [s]) == [100: .unseen, 101: .unseen])
        // Only one is known here: which one can't be told either.
        #expect(p.update([ours(100, "New Tab")], in: [s]) == [100: .unseen])
    }

    @Test func theFocusTellsThemApartAndTheOtherIsWhatIsLeft() {
        var p = WindowPairing()
        let found = p.update([ours(100, "New Tab"), ours(101, "New Tab", focused: true)],
                             in: [session("/a", [theirs(1, "New Tab", focused: true), theirs(2, "New Tab")])])
        #expect(found == [100: hit("/a", 2), 101: hit("/a", 1)])
        #expect(!p.isCertain(101))
    }

    @Test func aFocusPairingIsCorrectedByTheNextWordAndNeverShared() {
        var p = WindowPairing()
        func windows(_ focused: Int) -> [WindowPairing.Window] { [100, 101].map { ours($0, "New Tab", focused: $0 == focused) } }
        func theirWindows(_ focused: Int) -> [BrowserSession] { [session("/a", [1, 2].map { theirs($0, "New Tab", focused: $0 == focused) })] }
        #expect(p.update(windows(100), in: theirWindows(1)) == [100: hit("/a", 1), 101: hit("/a", 2)])
        // macOS has moved on to the other window, the browser's word is on its way.
        let between = p.update(windows(101), in: theirWindows(1))
        #expect(between[100] != between[101])
        #expect(p.update(windows(101), in: theirWindows(2)) == [100: hit("/a", 1), 101: hit("/a", 2)])
        // Focus unknown: kept.
        #expect(p.update(windows(0), in: theirWindows(0)) == [100: hit("/a", 1), 101: hit("/a", 2)])
    }

    @Test func theFocusPairsAWindowWhoseTitleHasNotArrived() {
        var p = WindowPairing()
        let found = p.update([ours(100, "Docs", focused: true)], in: [session("/a", [theirs(1, "Loading", focused: true), theirs(2, "Other")])])
        #expect(found == [100: hit("/a", 1)])
    }

    @Test func aStaleFocusIsNotTakenWhenBothTitleAndFrameSayOtherwise() {
        var p = WindowPairing()
        let found = p.update([ours(101, "Secret (Incognito)", at: 900, focused: true)], in: [session("/a", [theirs(1, "Inbox", focused: true)])])
        #expect(found == [101: .unseen])
    }

    @Test func anIncognitoWindowTheExtensionCannotSeeShowsNoOtherWindowsTabs() {
        var p = WindowPairing()
        let s = session("/a", [theirs(1, "Inbox")])
        #expect(p.update([ours(100, "Secret - Google Chrome (Incognito)")], in: [s]) == [100: .unseen])
        // On top of the regular window, untitled so far: that one is taken.
        #expect(p.update([ours(100, ""), ours(101, "Inbox - Google Chrome")], in: [s]) == [100: .unseen, 101: hit("/a", 1)])
    }

    @Test func aPageStillLoadingIsMatchedByItsFrameAlone() {
        let s = session("/a", [theirs(1, ""), theirs(2, "Docs", at: 800)])
        for title in ["Untitled - Google Chrome", ""] {
            var p = WindowPairing()
            #expect(p.update([ours(100, title)], in: [s]) == [100: hit("/a", 1)])
            #expect(!p.isCertain(100))
        }
    }

    @Test func aWindowPairedByItsFrameAloneIsLetGoWhenItsTitleSaysOtherwise() {
        // An Incognito window the extension can't see, exactly on a regular
        // window that isn't followed yet (another Space), untitled so far.
        var p = WindowPairing()
        let s = session("/a", [theirs(1, "Inbox")])
        #expect(p.update([ours(100, "")], in: [s]) == [100: hit("/a", 1)])
        #expect(p.update([ours(100, "Secret - Google Chrome (Incognito)")], in: [s]) == [100: .unseen])
        // One whose title then agrees is kept.
        _ = p.update([ours(101, "")], in: [s])
        #expect(p.update([ours(101, "Inbox - Google Chrome")], in: [s]) == [101: hit("/a", 1)])
        #expect(p.isCertain(101))
    }

    @Test func withoutFramesTheTitleAloneDecidesWhenOneWindowHasIt() {
        func frameless(_ id: Int, _ title: String) -> SnapshotWindow {
            SnapshotWindow(id: id, focused: false, tabs: [Tab(id: id * 10, windowId: id, title: title, active: true)])
        }
        var p = WindowPairing()
        let found = p.update([ours(100, "Docs - Brave"), ours(101, "Neither")], in: [session("/a", [frameless(1, "Inbox"), frameless(2, "Docs")])])
        #expect(found == [100: hit("/a", 2), 101: .unseen])
    }

    @Test func aClosedWindowFreesItsIdAndAReusedIdIsMatchedAfresh() {
        var p = WindowPairing()
        _ = p.update([ours(100, "Inbox")], in: [session("/a", [theirs(1, "Inbox")])])
        // The browser window is gone: so is the pairing.
        #expect(p.update([ours(100, "Inbox")], in: [session("/a", [theirs(2, "Docs", at: 900)])]) == [100: .unseen])
        _ = p.update([ours(100, "Inbox")], in: [session("/a", [theirs(1, "Inbox")])])
        // Ours is gone and another has come; the browser gave the new one the old id.
        #expect(p.update([ours(105, "Docs", at: 900)], in: [session("/a", [theirs(1, "Docs", at: 900)])]) == [105: hit("/a", 1)])
        #expect(!p.isCertain(100))
    }

    @Test func twoBrowsersWithTheSameWindowIdsStayApart() {
        var p = WindowPairing()
        let chrome = session("/chrome", [theirs(1, "Inbox")]), brave = session("/brave", pid: 8, [theirs(1, "Inbox")])
        #expect(p.update([ours(100, "Inbox"), ours(200, "Inbox", pid: 8)], in: [chrome, brave]) == [100: hit("/chrome", 1), 200: hit("/brave", 1)])
    }

    @Test func aSessionWhoseProcessIsNotKnownIsFoundByTheBrowsersName() {
        var p = WindowPairing()
        #expect(p.update([ours(100, "Inbox")], in: [session("/a", pid: 0, [theirs(1, "Inbox")])]) == [100: hit("/a", 1)])
    }

    @Test func aBrowserWithNoExtensionConnectedIsNotConnected() {
        var p = WindowPairing()
        #expect(p.update([ours(100, "Inbox")], in: []) == [100: .notConnected])
    }
}
