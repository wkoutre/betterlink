import Foundation
import Testing
@testable import BetterlinkCore

struct SidebarHoldsTests {
    let mail = SavedLink(title: "Mail", url: "https://mail.example/")
    let docs = SavedLink(title: "Docs", url: "https://docs.example/home")
    func tab(_ id: Int, _ url: String) -> OpenTab { OpenTab(id: id, url: url) }

    @Test func aTabAtASavedAddressShowsWithItsLinkAndASecondOneStaysInTheList() {
        let r = LinkResolution(links: [mail, docs], tabs: [tab(1, "https://other.example/"), tab(2, "https://mail.example"),
                                                           tab(3, "https://mail.example/#top")])
        #expect(r.tab(for: mail.id) == 2)
        #expect(r.tab(for: docs.id) == nil)
        #expect(r.claimed == [2])
        #expect(r.away.isEmpty)
    }

    @Test func aHeldTabStaysWithItsLinkWhereverItNavigates() {
        var holds = LinkHolds()
        holds.hold(7, for: mail.id)
        // The saved address redirected to the inbox, and then a message was opened.
        let r = LinkResolution(links: [mail, docs], tabs: [tab(7, "https://mail.example/u/0/inbox/42"), tab(8, "https://x.example/")], holds: holds)
        #expect(r.tab(for: mail.id) == 7)
        #expect(r.isAway(mail.id))
        #expect(r.claimed == [7])
        // Back on the saved page: still its tab, no longer away.
        let home = LinkResolution(links: [mail], tabs: [tab(7, "https://mail.example/")], holds: holds)
        #expect(home.tab(for: mail.id) == 7)
        #expect(!home.isAway(mail.id))
    }

    @Test func aTabThatOnlyMatchedIsLetGoWhenItNavigatesAway() {
        let before = LinkResolution(links: [mail], tabs: [tab(4, "https://mail.example/")])
        #expect(before.tab(for: mail.id) == 4)
        let after = LinkResolution(links: [mail], tabs: [tab(4, "https://mail.example/settings")])
        #expect(after.tab(for: mail.id) == nil)
        #expect(after.claimed.isEmpty)
    }

    @Test func aHeldTabIsNotTakenByAnotherLinkWhoseAddressItIsOn() {
        var holds = LinkHolds()
        holds.hold(7, for: mail.id)
        // The mail tab wandered onto the docs page; docs has its own tab too.
        let r = LinkResolution(links: [mail, docs], tabs: [tab(7, "https://docs.example/home"), tab(9, "https://docs.example/home")], holds: holds)
        #expect(r.tab(for: mail.id) == 7)
        #expect(r.tab(for: docs.id) == 9)
        // Alone, the held tab still belongs to mail, and docs shows closed.
        let alone = LinkResolution(links: [mail, docs], tabs: [tab(7, "https://docs.example/home")], holds: holds)
        #expect(alone.tab(for: docs.id) == nil)
        #expect(alone.claimed == [7])
    }

    @Test func theHeldTabWinsOverAnEarlierTabAtTheSameAddress() {
        var holds = LinkHolds()
        holds.hold(5, for: mail.id)
        let r = LinkResolution(links: [mail], tabs: [tab(2, "https://mail.example/"), tab(5, "https://mail.example/inbox")], holds: holds)
        #expect(r.tab(for: mail.id) == 5)
        #expect(r.claimed == [5], "the look-alike stays in the tab list")
    }

    @Test func eachWindowResolvesItsOwnHeldTab() {
        var holds = LinkHolds()
        holds.hold(1, for: mail.id)
        holds.hold(2, for: mail.id)
        #expect(holds.tabs(heldBy: mail.id) == [1, 2])
        #expect(LinkResolution(links: [mail], tabs: [tab(1, "https://mail.example/a")], holds: holds).tab(for: mail.id) == 1)
        #expect(LinkResolution(links: [mail], tabs: [tab(2, "https://mail.example/b")], holds: holds).tab(for: mail.id) == 2)
        // Both dragged into one window: the first is the link's, the other is a plain tab.
        let both = LinkResolution(links: [mail], tabs: [tab(2, "https://mail.example/b"), tab(1, "https://mail.example/a")], holds: holds)
        #expect(both.tab(for: mail.id) == 2)
        #expect(both.claimed == [2])
    }

    @Test func aTabHeldForAnotherSidebarProfileIsAnOrdinaryTabHere() {
        var holds = LinkHolds()
        holds.hold(3, for: UUID()) // a link in a Sidebar Profile not shown now
        let r = LinkResolution(links: [mail], tabs: [tab(3, "https://mail.example/")], holds: holds)
        #expect(r.tab(for: mail.id) == 3)
        #expect(!r.isAway(mail.id))
    }

    @Test func twoLinksAtOneAddressTakeOneTabEach() {
        let twin = SavedLink(title: "Mail again", url: "https://mail.example/")
        let r = LinkResolution(links: [mail, twin], tabs: [tab(1, "https://mail.example/"), tab(2, "https://mail.example/")])
        #expect(r.tab(for: mail.id) == 1)
        #expect(r.tab(for: twin.id) == 2)
    }

    @Test func closedTabsAndRemovedLinksAreForgotten() {
        var holds = LinkHolds()
        holds.hold(1, for: mail.id)
        holds.hold(2, for: docs.id)
        let nothing = holds.prune(tabs: [1, 2, 3], links: [mail.id, docs.id])
        #expect(!nothing)
        let closed = holds.prune(tabs: [2, 3], links: [mail.id, docs.id])
        #expect(closed)
        #expect(holds.link(holding: 1) == nil)
        let removed = holds.prune(tabs: [2], links: [mail.id])
        #expect(removed)
        #expect(holds.isEmpty)
        holds.hold(4, for: mail.id)
        holds.hold(5, for: mail.id)
        holds.release(tab: 4)
        #expect(holds.tabs(heldBy: mail.id) == [5])
        holds.release(link: mail.id)
        #expect(holds.isEmpty)
    }

    @Test func heldTabsComeBackToTheirLinksAfterABrowserRestart() {
        var before = LinkHolds()
        before.hold(11, for: mail.id)
        before.hold(12, for: docs.id)
        let open = [tab(11, "https://mail.example/u/0/inbox"), tab(12, "https://docs.example/d/abc"), tab(13, "https://loose.example/")]
        let remembered = before.addresses(of: open)
        #expect(remembered == [mail.id: ["https://mail.example/u/0/inbox"], docs.id: ["https://docs.example/d/abc"]])

        // The browser restarts: the same pages, new tab ids. Docs was removed meanwhile.
        var after = LinkHolds()
        let restored = [tab(101, "https://loose.example/"), tab(102, "https://mail.example/u/0/inbox"), tab(103, "https://docs.example/d/abc")]
        after.restore(remembered, tabs: restored, links: [mail.id])
        #expect(after.link(holding: 102) == mail.id)
        #expect(after.link(holding: 103) == nil)
        let r = LinkResolution(links: [mail], tabs: restored, holds: after)
        #expect(r.tab(for: mail.id) == 102)
        #expect(r.isAway(mail.id))
    }

    @Test func restoreNeverTakesATabSomethingAlreadyHolds() {
        var holds = LinkHolds()
        holds.hold(1, for: docs.id)
        holds.restore([mail.id: ["https://a.example/"]], tabs: [tab(1, "https://a.example/"), tab(2, "https://a.example/")], links: [mail.id, docs.id])
        #expect(holds.link(holding: 1) == docs.id)
        #expect(holds.link(holding: 2) == mail.id)
    }

    @Test func repointSavesTheCurrentPageOverALinkOrAFavorite() {
        var p = SidebarProfile(name: "Primary")
        let folder = p.addFolder("Work")
        p.addLink(SavedLink(id: docs.id, title: "Docs", url: docs.url, icon: "data:old"), in: folder)
        p.addFavorite(mail)
        p.repoint(docs.id, to: "https://docs.example/d/abc", title: " Spec ", icon: "data:new")
        p.repoint(mail.id, to: "https://mail.example/u/1/")
        p.repoint(docs.id, to: "") // nothing to point at
        #expect(p.savedLink(docs.id) == SavedLink(id: docs.id, title: "Spec", url: "https://docs.example/d/abc", icon: "data:new"))
        #expect(p.savedLink(mail.id)?.url == "https://mail.example/u/1/")
        #expect(p.savedLink(mail.id)?.title == "Mail")
        #expect(p.savedLink(UUID()) == nil)
        #expect(SidebarLibrary(profiles: [p]).allLinkIDs == [mail.id, docs.id])
    }

    @Test func anAddressIsParsedOnceHoweverOftenItIsCompared() {
        var parses = 0
        let address = "https://Count.Example/once/#\(UUID().uuidString)"
        for _ in 0..<50 { _ = PageKeys.key(address) { parses += 1; return SavedLink.computeKey($0) } }
        #expect(parses == 1)
        #expect(SavedLink.key(address) == SavedLink.computeKey(address))
        #expect(PageKeys.count <= PageKeys.limit)
    }

    /// The sidebar works this out on every tab event. With 300 tabs and 200
    /// saved links the old way (compare every link with every tab, for every
    /// tab row) parsed tens of millions of addresses; one pass must stay well
    /// under a frame's worth of work, with room for a slow CI machine.
    @Test func aHeavySessionResolvesInOnePass() {
        let links = (0..<200).map { SavedLink(title: "L\($0)", url: "https://site\($0).example/page") }
        let tabs = (0..<300).map { OpenTab(id: $0, url: "https://site\($0 % 250).example/page#\($0)") }
        var holds = LinkHolds()
        for i in 0..<50 { holds.hold(i, for: links[199 - i].id) }
        _ = LinkResolution(links: links, tabs: tabs, holds: holds) // fills the address table
        let start = Date()
        var r = LinkResolution()
        for _ in 0..<20 { r = LinkResolution(links: links, tabs: tabs, holds: holds) }
        let each = Date().timeIntervalSince(start) / 20
        #expect(each < 0.02, "one resolve took \(each * 1000) ms")
        #expect(r.tabs.count == 200)
        #expect(r.claimed.count == 200)
        #expect(r.away.count == 50)
    }
}
