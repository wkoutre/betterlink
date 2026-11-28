import Foundation
import Testing
@testable import BetterlinkCore

/// Picking several rows (Command-click, Shift-click) and what one action on
/// them does to a Sidebar Profile.
@Suite struct SidebarSelectionTests {
    private let rows: [SidebarRowID] = [.tab(1), .tab(2), .tab(3), .tab(4), .tab(5)]

    // MARK: Picking

    /// Nick's ask: click a tab, hold Shift, click one further down, and both
    /// and everything between are picked.
    @Test func shiftClickTakesTheRangeFromTheRowLastClicked() {
        var s = SidebarSelection()
        s.click(.tab(2))
        #expect(s.isEmpty)
        s.extend(to: .tab(4), current: .tab(2), in: rows)
        #expect(s.rows == [.tab(2), .tab(3), .tab(4)])
        // Another Shift-click moves the end of the same range, upward too.
        s.extend(to: .tab(5), current: .tab(2), in: rows)
        #expect(s.rows == [.tab(2), .tab(3), .tab(4), .tab(5)])
        s.extend(to: .tab(1), current: .tab(2), in: rows)
        #expect(s.rows == [.tab(1), .tab(2)])
    }

    /// With nothing clicked in the sidebar yet, the range starts at the tab
    /// you are on; with neither, at the row itself.
    @Test func shiftClickStartsAtTheCurrentTabWhenNothingWasClicked() {
        var s = SidebarSelection()
        s.extend(to: .tab(1), current: .tab(3), in: rows)
        #expect(s.rows == [.tab(1), .tab(2), .tab(3)])
        var alone = SidebarSelection()
        alone.extend(to: .tab(4), current: nil, in: rows)
        #expect(alone.rows == [.tab(4)])
        // The row last clicked has gone (its tab closed): the current tab again.
        var gone = SidebarSelection()
        gone.click(.tab(9))
        gone.extend(to: .tab(5), current: .tab(4), in: rows)
        #expect(gone.rows == [.tab(4), .tab(5)])
    }

    /// Command-click adds to the tab you are on, as in a browser's tab strip,
    /// and takes a picked row out again.
    @Test func commandClickAddsAndRemoves() {
        var s = SidebarSelection()
        s.toggle(.tab(4), current: .tab(1), in: rows)
        #expect(s.rows == [.tab(1), .tab(4)])
        s.toggle(.tab(2), current: .tab(1), in: rows)
        #expect(s.rows == [.tab(1), .tab(2), .tab(4)])
        s.toggle(.tab(1), current: .tab(1), in: rows) // not the tab you are on, after all
        #expect(s.rows == [.tab(2), .tab(4)])
        s.toggle(.tab(4), current: .tab(1), in: rows)
        #expect(s.rows == [.tab(2)])
    }

    @Test func commandClickOnTheCurrentTabPicksItAlone() {
        var s = SidebarSelection()
        s.toggle(.tab(1), current: .tab(1), in: rows)
        #expect(s.rows == [.tab(1)])
        // No current row on screen: only what was clicked.
        var other = SidebarSelection()
        other.toggle(.tab(3), current: .tab(9), in: rows)
        #expect(other.rows == [.tab(3)])
        other.toggle(.tab(8), current: nil, in: rows) // not a row on screen
        #expect(other.rows == [.tab(3)])
    }

    /// Command-click moves where the next Shift-click's range starts.
    @Test func shiftClickAfterCommandClickRangesFromIt() {
        var s = SidebarSelection()
        s.toggle(.tab(4), current: nil, in: rows)
        s.extend(to: .tab(2), current: nil, in: rows)
        #expect(s.rows == [.tab(2), .tab(3), .tab(4)])
    }

    @Test func aPlainClickPicksNothing() {
        var s = SidebarSelection()
        s.toggle(.tab(4), current: .tab(1), in: rows)
        s.click(.tab(3))
        #expect(s.isEmpty && s.anchor == .tab(3))
        s.toggle(.tab(4), current: .tab(3), in: rows)
        s.clear()
        #expect(s.isEmpty && s.anchor == .tab(4))
    }

    @Test func rowsThatLeaveTheScreenAreNoLongerPicked() {
        var s = SidebarSelection()
        s.click(.tab(2))
        s.extend(to: .tab(4), current: nil, in: rows)
        let kept = s.kept(in: [.tab(1), .tab(3), .tab(4)])
        #expect(kept.rows == [.tab(3), .tab(4)] && kept.anchor == nil)
        #expect(s.kept(in: rows) == s)
        #expect(s.ordered(in: rows.reversed()) == [.tab(4), .tab(3), .tab(2)])
    }

    // MARK: What is picked

    private func link(_ t: String) -> SavedLink { SavedLink(title: t, url: "https://\(t).example") }
    private func titles(_ items: [SidebarItem]) -> [String] {
        items.map {
            switch $0 {
            case .folder(let f): return "[\(f.name)]"
            case .link(let l): return l.title
            }
        }
    }

    /// a b [F: x [G: z] y] c, favorites p q
    private func sample() -> (SidebarProfile, f: UUID, g: UUID, ids: [String: UUID]) {
        var p = SidebarProfile(name: "P")
        var ids: [String: UUID] = [:]
        for t in ["a", "b"] { let l = link(t); ids[t] = l.id; p.addLink(l) }
        let f = p.addFolder("F")
        let x = link("x"); ids["x"] = x.id; p.addLink(x, in: f)
        let g = p.addFolder("G", in: f)
        let z = link("z"); ids["z"] = z.id; p.addLink(z, in: g)
        let y = link("y"); ids["y"] = y.id; p.addLink(y, in: f)
        let c = link("c"); ids["c"] = c.id; p.addLink(c)
        for t in ["p", "q"] { let l = link(t); ids[t] = l.id; p.addFavorite(l) }
        return (p, f, g, ids)
    }

    @Test func partsNameTabsSavedThingsAndTheLinksInside() {
        let (p, f, g, ids) = sample()
        let visible = SidebarRows.visible(p, active: [], tabs: [7, 8])
        var s = SidebarSelection()
        s.click(.favorite(ids["q"]!))
        s.extend(to: .tab(7), current: nil, in: visible) // q, everything saved, the first tab
        let parts = s.parts(in: visible, of: p)
        #expect(parts.tabs == [7])
        // x, G, z and y are inside F, which is picked too: F carries them.
        #expect(parts.saved == [ids["q"]!, ids["a"]!, ids["b"]!, f, ids["c"]!])
        #expect(parts.links.map(\.title) == ["q", "a", "b", "x", "z", "y", "c"])
        #expect(parts.hasFolder && parts.hasFullFolder)
        _ = g

        var one = SidebarSelection()
        one.toggle(.link(ids["z"]!), current: nil, in: visible)
        one.toggle(.tab(8), current: nil, in: visible)
        let few = one.parts(in: visible, of: p)
        #expect(few.tabs == [8] && few.saved == [ids["z"]!] && !few.hasFolder && !few.isEmpty)
        #expect(SidebarSelection().parts(in: visible, of: p).isEmpty)
    }

    @Test func theCurrentRowIsTheActiveTabsOrItsSavedLinks() {
        let (p, _, _, ids) = sample()
        let visible = SidebarRows.visible(p, active: [], tabs: [7, 8])
        #expect(SidebarRows.current(in: visible, activeTab: 8, activeLinks: []) == .tab(8))
        #expect(SidebarRows.current(in: visible, activeTab: 3, activeLinks: [ids["y"]!]) == .link(ids["y"]!))
        #expect(SidebarRows.current(in: visible, activeTab: 3, activeLinks: [ids["p"]!]) == .favorite(ids["p"]!))
        #expect(SidebarRows.current(in: visible, activeTab: nil, activeLinks: []) == nil)
    }

    // MARK: One action on several

    @Test func rootsLeaveOutWhatAPickedFolderCarries() {
        let (p, f, g, ids) = sample()
        #expect(p.roots(of: [ids["z"]!, g, ids["a"]!, ids["a"]!, UUID()]) == [g, ids["a"]!])
        #expect(p.roots(of: [ids["x"]!, f, ids["z"]!, ids["p"]!]) == [f, ids["p"]!])
    }

    /// Several moved within their own list land together and in order, before
    /// the row they were dropped on: one at a time, the second went past it.
    @Test func severalMoveTogetherWithinAList() {
        var (p, _, _, ids) = sample()
        p.place([ids["a"]!, ids["b"]!], at: .items(parent: nil, index: 3)) // before c
        #expect(titles(p.items) == ["[F]", "a", "b", "c"])
        p.place([ids["c"]!, ids["a"]!], at: .items(parent: nil, index: 0)) // in the order given
        #expect(titles(p.items) == ["c", "a", "[F]", "b"])
        p.place([ids["a"]!, ids["b"]!], at: .items(parent: nil, index: .max))
        #expect(titles(p.items) == ["c", "[F]", "a", "b"])
    }

    @Test func severalMoveIntoAFolderFromEverywhere() {
        var (p, f, g, ids) = sample()
        let moved = p.place([ids["p"]!, ids["a"]!, ids["z"]!, ids["c"]!], at: .items(parent: f, index: 1))
        #expect(moved.count == 4)
        #expect(titles(p.children(of: f)) == ["x", "p", "a", "z", "c", "[G]", "y"])
        #expect(titles(p.items) == ["b", "[F]"] && p.favorites.map(\.title) == ["q"])
        #expect(p.children(of: g).isEmpty)
    }

    @Test func aFolderNeverMovesIntoItselfAndTheRestStillMove() {
        var (p, f, g, ids) = sample()
        let moved = p.place([ids["a"]!, f, g], at: .items(parent: g, index: 0))
        // F holds G, and G is G: only a moves.
        #expect(moved == [ids["a"]!])
        #expect(titles(p.children(of: g)) == ["a", "z"] && p.parent(of: g) == f)
        #expect(p.place([ids["b"]!], at: .items(parent: UUID(), index: 0)).isEmpty) // no such folder
    }

    @Test func severalBecomeFavoritesOncePerAddress() {
        var (p, f, _, ids) = sample()
        var twin = link("twin")
        twin.url = "https://p.example/" // the page favorite p already is
        p.addLink(twin)
        let moved = p.place([ids["a"]!, f, twin.id, ids["x"]!, ids["c"]!], at: .favorites(1))
        // The folder stays, with x that it carries, and so does the twin.
        #expect(moved == [ids["a"]!, ids["c"]!])
        #expect(p.favorites.map(\.title) == ["p", "a", "c", "q"])
        #expect(titles(p.items) == ["b", "[F]", "twin"] && p.parent(of: ids["x"]!) == f)
        // Reordering the grid's own: q and p to the front, q first.
        p.place([ids["q"]!, ids["p"]!], at: .favorites(0))
        #expect(p.favorites.map(\.title) == ["q", "p", "a", "c"])
    }

    /// Tabs dropped with saved things are saved right after them.
    @Test func newLinksAreSavedAfterTheMovedOnes() {
        var (p, f, _, ids) = sample()
        let t1 = link("t1"), t2 = link("t2")
        let placed = p.place([ids["c"]!], adding: [t1, t2], at: .items(parent: f, index: 0))
        #expect(placed == [ids["c"]!, t1.id, t2.id])
        #expect(titles(p.children(of: f)) == ["c", "t1", "t2", "x", "[G]", "y"])
        // Into the grid: one whose address is a favorite already is not saved twice.
        var again = link("again")
        again.url = "https://q.example"
        let t3 = link("t3")
        #expect(p.place([], adding: [again, t3], at: .favorites(.max)) == [t3.id])
        #expect(p.favorites.map(\.title) == ["p", "q", "t3"])
        #expect(p.place([], adding: [], at: .favorites(0)).isEmpty)
    }

    /// Finder's New Folder with Selection: the folder stands where the first
    /// picked thing stood.
    @Test func aNewFolderTakesThePlaceOfTheFirstPicked() {
        var (p, f, _, ids) = sample()
        let tab = link("tab")
        let made = p.addFolder("New", holding: [ids["q"]!, ids["x"]!, ids["c"]!], and: [tab])
        // q is a Favorite; x is the first among the folders, inside F.
        #expect(p.parent(of: made) == f)
        #expect(titles(p.children(of: f)) == ["[New]", "[G]", "y"])
        #expect(titles(p.children(of: made)) == ["q", "x", "c", "tab"])
        #expect(p.favorites.map(\.title) == ["p"] && titles(p.items) == ["a", "b", "[F]"])
    }

    @Test func aNewFolderForTabsAndFavoritesGoesToTheEndOfTheTopLevel() {
        var (p, _, _, ids) = sample()
        let made = p.addFolder("New", holding: [ids["p"]!], and: [link("t")])
        #expect(titles(p.items) == ["a", "b", "[F]", "c", "[New]"])
        #expect(titles(p.children(of: made)) == ["p", "t"])
        // A picked folder goes into the new one, which takes its place.
        var (q, f, _, more) = sample()
        let wrap = q.addFolder("Wrap", holding: [f, more["c"]!])
        #expect(titles(q.items) == ["a", "b", "[Wrap]"] && titles(q.children(of: wrap)) == ["[F]", "c"])
    }

    @Test func severalAreRemovedAndPutBackWhereTheyWere() {
        let (start, f, _, ids) = sample()
        var p = start
        let removed = p.take([ids["p"]!, ids["a"]!, ids["x"]!, f, ids["c"]!])
        // x went with F.
        #expect(removed.map(\.item.id) == [ids["p"]!, ids["a"]!, f, ids["c"]!])
        #expect(titles(p.items) == ["b"] && p.favorites.map(\.title) == ["q"])
        p.restore(removed)
        #expect(p == start)
        // Undo after more changes: what is still missing comes back, the rest is left alone.
        var later = start
        let gone = later.take([ids["a"]!, ids["b"]!])
        later.restore(gone[1])
        later.restore(gone)
        #expect(titles(later.items) == ["a", "b", "[F]", "c"])
    }

    @Test func aDragCarriesSeveralKeys() {
        let keys = ["betterlink-saved:\(UUID().uuidString)", "betterlink-tab:3:17", "betterlink-tab:3:18"]
        #expect(SidebarDrag.keys(in: SidebarDrag.joined(keys)) == keys)
        #expect(SidebarDrag.keys(in: keys[0]) == [keys[0]])
        #expect(SidebarDrag.keys(in: "").isEmpty)
    }
}
