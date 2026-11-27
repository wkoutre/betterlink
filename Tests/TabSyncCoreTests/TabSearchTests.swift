import Testing
@testable import TabSyncCore

struct TabSearchTests {
    func item(_ id: Int, _ title: String, _ url: String, in path: String = "/a.sock") -> TabSearch.Item {
        .init(socketPath: path, tab: Tab(id: id, windowId: 1, title: title, url: url))
    }

    @Test func everyWordMustAppearInTheTitleOrAddressInAnyOrder() {
        let items = [
            item(1, "Inbox (3) - me@example.com - Gmail", "https://mail.google.com/mail/u/0/#inbox"),
            item(2, "Pull request #98", "https://github.com/wkoutre/betterlink/pull/98"),
            item(3, "Calendar", "https://calendar.google.com/"),
        ]
        #expect(TabSearch.find("gmail", in: items).map(\.tab.id) == [1])
        #expect(TabSearch.find("98 BETTERLINK", in: items).map(\.tab.id) == [2])
        #expect(TabSearch.find("google", in: items).map(\.tab.id) == [1, 3])
        #expect(TabSearch.find("google nothing", in: items).isEmpty)
    }

    @Test func nothingTypedFindsNothing() {
        #expect(TabSearch.find("   ", in: [item(1, "A", "https://a.example/")]).isEmpty)
    }

    @Test func aTitleThatStartsWithItComesFirstThenAWordThatDoes() {
        let items = [
            item(1, "The docs", "https://x.example/"),
            item(2, "Redocs", "https://y.example/"),
            item(3, "Docs home", "https://z.example/"),
        ]
        #expect(TabSearch.find("docs", in: items).map(\.tab.id) == [3, 1, 2])
    }

    @Test func theAddressIsReadWithoutSchemeOrWww() {
        #expect(TabSearch.shown("https://www.example.com/a") == "example.com/a")
        #expect(TabSearch.shown("file:///Users/me/a.pdf") == "/Users/me/a.pdf")
        let items = [item(1, "Untitled", "https://www.example.com/"), item(2, "Example notes", "https://notes.test/")]
        // Both start with it: the given order decides.
        #expect(TabSearch.find("example", in: items).map(\.tab.id) == [1, 2])
    }

    @Test func tabsFromEveryBrowserProfileAreSearched() {
        var a = BrowserSession(socketPath: "/a.sock")
        var snap = Inbound(type: "snapshot")
        snap.seq = 1
        snap.windows = [SnapshotWindow(id: 1, focused: true, tabs: [Tab(id: 10, windowId: 1, title: "Work mail", url: "https://mail.example/")])]
        a.store.apply(snap)
        var b = BrowserSession(socketPath: "/b.sock")
        snap.windows = [SnapshotWindow(id: 5, focused: true, tabs: [Tab(id: 10, windowId: 5, title: "Home mail", url: "https://mail.example/")])]
        b.store.apply(snap)
        let found = TabSearch.find("mail", in: TabSearch.items([a, b]))
        #expect(found.map(\.socketPath) == ["/a.sock", "/b.sock"])
        #expect(TabSearch.find("x", in: [], limit: 1).isEmpty)
    }

    @Test func atMostTheLimit() {
        let items = (0..<10).map { item($0, "Tab \($0)", "https://t\($0).example/") }
        #expect(TabSearch.find("tab", in: items, limit: 3).map(\.tab.id) == [0, 1, 2])
    }
}
