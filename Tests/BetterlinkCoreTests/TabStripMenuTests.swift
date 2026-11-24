import Testing
@testable import BetterlinkCore

@Suite struct TabStripMenuTests {
    let menus: [(title: String, items: [String])] = [
        ("Chrome", ["About Google Chrome"]),
        ("View", ["Always Show Bookmarks Bar", "Show Tabs Vertically", "Collapse Vertical Tabs"]),
        ("History", ["How to show tabs vertically", "Collapse Vertical Tabs"]),
        ("Bookmarks", ["Show Tabs Vertically"]),
    ]

    @Test func findsTheItemsInTheViewMenu() {
        #expect(TabStripMenu.locate(TabStripMenu.showVertically, in: menus)! == (1, 1))
        #expect(TabStripMenu.locate(TabStripMenu.collapse, in: menus)! == (1, 2))
    }

    @Test func neverPressesAPageTitledItemElsewhere() {
        // A browser without the View item: history and bookmarks with the same
        // or a similar title must not match.
        let noView = menus.map { $0.title == "View" ? (title: "View", items: ["Always Show Bookmarks Bar"]) : $0 }
        #expect(TabStripMenu.locate(TabStripMenu.showVertically, in: noView) == nil)
        #expect(TabStripMenu.locate(TabStripMenu.collapse, in: noView) == nil)
    }

    @Test func titlesMustMatchExactly() {
        let near: [(title: String, items: [String])] = [("View", ["Show tabs vertically (beta)", "collapse vertical tabs"])]
        #expect(TabStripMenu.locate(TabStripMenu.showVertically, in: near) == nil)
        #expect(TabStripMenu.locate(TabStripMenu.collapse, in: near) == nil)
    }
}
