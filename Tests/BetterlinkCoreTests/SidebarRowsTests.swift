import Foundation
import Testing
@testable import BetterlinkCore

@Suite struct SidebarRowsTests {
    private let fav = SavedLink(title: "F", url: "https://f.example")
    private let a = SavedLink(title: "A", url: "https://a.example")
    private let b = SavedLink(title: "B", url: "https://b.example")

    private func profile(expanded: Bool) -> (SidebarProfile, UUID) {
        var p = SidebarProfile(name: "P")
        p.addFavorite(fav)
        let f = p.addFolder("Folder")
        p.addLink(a, in: f)
        p.addLink(b, in: f)
        // Adding into a folder opens it.
        if !expanded { p.toggleExpanded(f) }
        return (p, f)
    }

    @Test func favoritesThenItemsThenTabs() {
        let (p, f) = profile(expanded: true)
        #expect(SidebarRows.visible(p, active: [], tabs: [7, 8])
            == [.favorite(fav.id), .folder(f), .link(a.id), .link(b.id), .tab(7), .tab(8)])
        // Open, a folder shows everything whichever tab is active.
        #expect(SidebarRows.visible(p, active: [b.id], tabs: [])
            == [.favorite(fav.id), .folder(f), .link(a.id), .link(b.id)])
    }

    /// Like Dia: closed, a folder shows only the tab you are on, when that tab
    /// is inside it, and folds away entirely when it isn't.
    @Test func aClosedFolderShowsOnlyTheActiveTab() {
        let (p, f) = profile(expanded: false)
        #expect(SidebarRows.visible(p, active: [b.id], tabs: []) == [.favorite(fav.id), .folder(f), .link(b.id)])
        // The active tab is a Favorite, or a loose tab: nothing peeks out.
        #expect(SidebarRows.visible(p, active: [fav.id], tabs: [7]) == [.favorite(fav.id), .folder(f), .tab(7)])
        #expect(SidebarRows.visible(p, active: [], tabs: []) == [.favorite(fav.id), .folder(f)])
    }

    @Test func aClosedFolderShowsTheActiveTabFromAFolderInsideIt() {
        var p = SidebarProfile(name: "P")
        let outer = p.addFolder("Outer")
        let inner = p.addFolder("Inner", in: outer)
        p.addLink(a, in: inner)
        p.addLink(b, in: outer)
        p.toggleExpanded(outer)
        #expect(SidebarRows.visible(p, active: [a.id], tabs: []) == [.folder(outer), .link(a.id)])
        guard case .folder(let f)? = SidebarProfile.find(outer, in: p.items) else { Issue.record("no folder"); return }
        #expect(SidebarRows.peek(f, active: [a.id]).map(\.id) == [a.id])
        #expect(SidebarRows.peek(f, active: []).isEmpty)
    }

    @Test func movingStopsAtTheEnds() {
        let rows: [SidebarRowID] = [.tab(1), .tab(2), .tab(3)]
        #expect(SidebarRows.move(nil, by: 1, in: rows) == .tab(1))
        #expect(SidebarRows.move(nil, by: -1, in: rows) == .tab(3))
        #expect(SidebarRows.move(.tab(1), by: 1, in: rows) == .tab(2))
        #expect(SidebarRows.move(.tab(1), by: -1, in: rows) == .tab(1))
        #expect(SidebarRows.move(.tab(3), by: 1, in: rows) == .tab(3))
        #expect(SidebarRows.move(nil, by: 1, in: []) == nil)
    }

    @Test func theCursorStaysOrTakesTheNextRow() {
        let old: [SidebarRowID] = [.tab(1), .tab(2), .tab(3)]
        #expect(SidebarRows.keep(.tab(2), from: old, to: [.tab(0)] + old) == .tab(2))
        #expect(SidebarRows.keep(.tab(2), from: old, to: [.tab(1), .tab(3)]) == .tab(3))
        #expect(SidebarRows.keep(.tab(3), from: old, to: [.tab(1), .tab(2)]) == .tab(2))
        #expect(SidebarRows.keep(.tab(1), from: old, to: []) == nil)
        #expect(SidebarRows.keep(nil, from: old, to: old) == nil)
    }

    /// Safari has no Tabs extension, so the sidebar can't show its tabs.
    @Test func onlyChromiumBrowsersHostTheSidebar() {
        #expect(!Browser.known(bundleId: "com.apple.Safari")!.hostsSidebar)
        #expect(!Browser.known(bundleId: "org.mozilla.firefox")!.hostsSidebar)
        #expect(Browser.known(bundleId: "com.google.Chrome")!.hostsSidebar)
        #expect(Browser.sidebarHosts(["com.apple.Safari", "com.google.Chrome", "unknown.app"]) == ["com.google.Chrome"])
    }
}
