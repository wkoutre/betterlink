import BetterlinkCore
import Foundation
import TabSyncCore
import Testing
@testable import Betterlink

@MainActor @Suite struct SidebarLookTests {
    private func session(_ windows: [SnapshotWindow], snapshot: Bool = true) -> BrowserSession {
        var s = BrowserSession(socketPath: "/a")
        s.browserPid = 7
        s.instance = "work"
        guard snapshot else { return s }
        var m = Inbound(type: "snapshot")
        m.seq = 1
        m.windows = windows
        s.store.apply(m)
        return s
    }
    private func window(_ id: Int, _ title: String, focused: Bool = false, left: Double = 0) -> SnapshotWindow {
        SnapshotWindow(id: id, focused: focused, tabs: [Tab(id: id * 10, windowId: id, title: title, active: true)],
                       left: left, top: 31, width: 748, height: 1259)
    }
    private func look(_ found: WindowPairing.Found, _ s: BrowserSession?, profiles: [String: SidebarLook.Profile] = [:],
                      ledger: HoldLedger = HoldLedger()) -> SidebarLook {
        .make(found, pid: 7, app: "Google Chrome", sessions: s.map { [$0] } ?? [], profiles: profiles, ledger: ledger)
    }
    private let first = WindowPairing.Found.window(.init(session: "/a", windowId: 1))

    /// With several sidebars on screen, a tab changing in one window must not
    /// redraw the others.
    @Test func anotherWindowsTabsLeaveThisWindowsLookAsItWas() {
        let before = look(first, session([window(1, "Inbox"), window(2, "Docs")]))
        #expect(before.match?.window?.tabs.map(\.title) == ["Inbox"])
        var busy = session([window(1, "Inbox"), window(2, "Docs (1)")])
        busy.lastEventLatencyMs = 3
        #expect(look(first, busy) == before)
        // Nor does this window moving or taking the focus: neither is shown.
        #expect(look(first, session([window(1, "Inbox", focused: true, left: 300), window(2, "Docs")])) == before)
        #expect(look(first, session([window(1, "Inbox (1)"), window(2, "Docs")])) != before)
    }

    @Test func itsProfileAndHeldTabsAreInTheLook() {
        let s = session([window(1, "Inbox")])
        let plain = look(first, s)
        let work = SidebarLook.Profile(ref: ProfileRef(browser: "com.google.Chrome", directory: "Profile 1"), name: "Work", color: 0x112233)
        let known = look(first, s, profiles: ["work": work])
        #expect(known.match?.profile == work)
        #expect(known != plain)
        var ledger = HoldLedger()
        ledger.hold(10, for: UUID(), in: "work")
        #expect(look(first, s, ledger: ledger) != plain)
    }

    @Test func aWindowWithNoTabsToShowSaysWhy() {
        #expect(look(.notConnected, nil) == .notConnected)
        #expect(look(.unseen, session([window(1, "Inbox")])) == .unseen)
        #expect(look(.unseen, session([], snapshot: false)) == .connecting)
        // The browser window closed between the pairing and now.
        #expect(look(.window(.init(session: "/gone", windowId: 1)), session([window(1, "Inbox")])) == .unseen)
    }
}
