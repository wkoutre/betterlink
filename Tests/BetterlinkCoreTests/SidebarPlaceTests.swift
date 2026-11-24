import Foundation
import Testing
@testable import BetterlinkCore

/// Drag and drop in the sidebar: every move goes through `place(_:at:)`.
struct SidebarPlaceTests {
    func link(_ t: String) -> SavedLink { SavedLink(title: t, url: "https://\(t).example") }
    func titles(_ items: [SidebarItem]) -> [String] {
        items.map { if case .folder(let f) = $0 { return "[\(f.name)]" } else if case .link(let l) = $0 { return l.title } else { return "" } }
    }

    /// a b [F: x y] c, favorites p q r
    func sample() -> (SidebarProfile, folder: UUID, ids: [String: UUID]) {
        var p = SidebarProfile(name: "P")
        var ids: [String: UUID] = [:]
        for t in ["a", "b"] { let l = link(t); ids[t] = l.id; p.addLink(l) }
        let f = p.addFolder("F")
        for t in ["x", "y"] { let l = link(t); ids[t] = l.id; p.addLink(l, in: f) }
        let c = link("c"); ids["c"] = c.id; p.addLink(c)
        for t in ["p", "q", "r"] { let l = link(t); ids[t] = l.id; p.addFavorite(l) }
        return (p, f, ids)
    }

    @Test func reordersWithinAList() {
        var (p, _, ids) = sample()
        p.place(ids["a"]!, at: .items(parent: nil, index: 3)) // drop a after [F]
        #expect(titles(p.items) == ["b", "[F]", "a", "c"])
        p.place(ids["c"]!, at: .items(parent: nil, index: 0)) // c to the top
        #expect(titles(p.items) == ["c", "b", "[F]", "a"])
        p.place(ids["p"]!, at: .favorites(3)) // first favorite to the end
        #expect(p.favorites.map(\.title) == ["q", "r", "p"])
        p.place(ids["p"]!, at: .favorites(1))
        #expect(p.favorites.map(\.title) == ["q", "p", "r"])
    }

    @Test func movesIntoAndOutOfFoldersAtAPosition() {
        var (p, f, ids) = sample()
        p.place(ids["a"]!, at: .items(parent: f, index: 1)) // between x and y
        #expect(titles(p.children(of: f)) == ["x", "a", "y"])
        #expect(titles(p.items) == ["b", "[F]", "c"])
        p.place(ids["y"]!, at: .items(parent: nil, index: 0)) // out to the top
        #expect(titles(p.items) == ["y", "b", "[F]", "c"])
        #expect(p.parent(of: ids["a"]!) == f && p.parent(of: ids["y"]!) == nil)
    }

    @Test func foldersNestButNeverIntoThemselves() {
        var (p, f, _) = sample()
        let g = p.addFolder("G")
        p.place(g, at: .items(parent: f, index: 0))
        #expect(p.parent(of: g) == f)
        let before = p
        p.place(f, at: .items(parent: g, index: 0)) // F into its own child
        p.place(f, at: .items(parent: f, index: 0)) // F into itself
        p.place(f, at: .favorites(0))               // a folder isn't a favorite
        #expect(p == before)
    }

    @Test func linksMoveBetweenFavoritesAndFolders() {
        var (p, f, ids) = sample()
        p.place(ids["q"]!, at: .items(parent: f, index: 2)) // a favorite into a folder
        #expect(p.favorites.map(\.title) == ["p", "r"])
        #expect(titles(p.children(of: f)) == ["x", "y", "q"])
        p.place(ids["b"]!, at: .favorites(0)) // a saved link into the grid
        #expect(p.favorites.map(\.title) == ["b", "p", "r"])
        #expect(titles(p.items) == ["a", "[F]", "c"])
        // A link whose address is already a favorite stays put.
        p.addLink(SavedLink(title: "dup", url: "https://p.example"))
        let dup = p.items.last!.id
        p.place(dup, at: .favorites(0))
        #expect(p.favorites.count == 3 && p.items.last?.id == dup)
    }

    @Test func missingTargetsChangeNothing() {
        var (p, _, ids) = sample()
        let before = p
        p.place(ids["a"]!, at: .items(parent: UUID(), index: 0))
        p.place(UUID(), at: .items(parent: nil, index: 0))
        p.place(ids["a"]!, at: .items(parent: ids["b"]!, index: 0)) // a link isn't a folder
        #expect(p == before)
    }

    @Test func aTabDraggedInIsSavedWhereItLands() {
        var (p, f, _) = sample()
        p.insert(link("new"), at: .items(parent: f, index: 1))
        #expect(titles(p.children(of: f)) == ["x", "new", "y"])
        p.insert(link("fav"), at: .favorites(0))
        #expect(p.favorites.first?.title == "fav")
        p.insert(SavedLink(title: "again", url: "https://fav.example"), at: .favorites(2))
        #expect(p.favorites.filter { $0.url == "https://fav.example" }.count == 1)
        p.insert(link("far"), at: .items(parent: nil, index: 99)) // clamped to the end
        #expect(p.items.last.map { titles([$0]) } == ["far"])
    }
}
