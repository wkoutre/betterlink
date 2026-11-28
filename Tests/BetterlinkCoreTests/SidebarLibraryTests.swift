import Foundation
import Testing
@testable import BetterlinkCore

struct SidebarLibraryTests {
    let chromeDefault = ProfileRef(browser: "com.google.Chrome", directory: "Default")
    let chromeClaude = ProfileRef(browser: "com.google.Chrome", directory: "Profile 1")

    @Test func eachBrowserProfileGetsItsLinkedSidebarProfileElseTheCatchAll() {
        let work = SidebarProfile(name: "Work", browserProfiles: [chromeClaude])
        let primary = SidebarProfile(name: "Primary")
        let lib = SidebarLibrary(profiles: [work, primary])
        #expect(lib.profile(for: chromeClaude)?.name == "Work")
        #expect(lib.profile(for: chromeDefault)?.name == "Primary")
        #expect(lib.profile(for: nil)?.name == "Primary")
        #expect(SidebarLibrary(profiles: [work]).profile(for: chromeDefault)?.name == "Work")
    }

    /// `tabs save` with no profile named: the one the tabs' sidebar shows,
    /// which for a browser profile that can't be told is the catch-all, as on
    /// screen; tabs whose sidebars show different profiles name none.
    @Test func theProfileSeveralTabsSidebarsShow() {
        let work = SidebarProfile(name: "Work", browserProfiles: [chromeClaude])
        let primary = SidebarProfile(name: "Primary")
        let lib = SidebarLibrary(profiles: [work, primary])
        #expect(lib.shownProfile(for: [nil]) == primary.id, "a profile that can't be told shows the catch-all")
        #expect(lib.shownProfile(for: [chromeDefault, nil]) == primary.id)
        #expect(lib.shownProfile(for: [chromeClaude, chromeClaude]) == work.id)
        #expect(lib.shownProfile(for: [chromeClaude, nil]) == nil, "two sidebars, two profiles: ask")
        #expect(lib.shownProfile(for: []) == nil)
    }

    @Test func linkingABrowserProfileMovesItToThatSidebarProfile() {
        let a = SidebarProfile(name: "A", browserProfiles: [chromeClaude]), b = SidebarProfile(name: "B")
        var lib = SidebarLibrary(profiles: [a, b])
        lib.link(chromeClaude, to: b.id)
        #expect(lib.profile(for: chromeClaude)?.name == "B")
        #expect(lib.profiles[0].browserProfiles.isEmpty)
        lib.removeProfile(a.id)
        lib.removeProfile(b.id)
        #expect(lib.profiles.map(\.name) == ["B"])
    }

    /// Option-click: every folder, at every depth, goes the way the clicked one went.
    @Test func everyFolderOpensOrClosesAtOnce() {
        var p = SidebarProfile(name: "P")
        let a = p.addFolder("A"), b = p.addFolder("B")
        let inner = p.addFolder("Inner", in: a)
        p.toggleExpanded(b)
        func states() -> [Bool] {
            [a, b, inner].map { id in
                if case .folder(let f)? = SidebarProfile.find(id, in: p.items) { return f.expanded }
                return false
            }
        }
        p.setAllExpanded(false)
        #expect(states() == [false, false, false])
        p.setAllExpanded(true)
        #expect(states() == [true, true, true])
        let before = p
        p.setAllExpanded(true) // already open: nothing changes
        #expect(p == before)
    }

    @Test func foldersNestAndLinksLandWhereTheyAreDropped() {
        var p = SidebarProfile(name: "Primary")
        let travel = p.addFolder("Travel")
        let flights = p.addFolder("Flights", in: travel)
        p.addLink(SavedLink(title: "Airline", url: "https://air.example/"), in: flights)
        p.addLink(SavedLink(title: "Top", url: "https://top.example/"))
        guard case .folder(let t) = p.items[0], case .folder(let f) = t.items[0] else { Issue.record("no folders"); return }
        #expect(f.name == "Flights")
        #expect(f.items.count == 1)
        #expect(p.allLinks.map(\.title) == ["Airline", "Top"])
    }

    @Test func renameRemoveAndCollapse() {
        var p = SidebarProfile(name: "Primary")
        let a = p.addFolder("A")
        p.rename(a, to: "  Shopping ")
        p.toggleExpanded(a)
        guard case .folder(let f) = p.items[0] else { Issue.record("no folder"); return }
        #expect(f.name == "Shopping")
        #expect(!f.expanded)
        p.rename(a, to: "   ")
        if case .folder(let f2) = p.items[0] { #expect(f2.name == "Shopping") }
        p.remove(a)
        #expect(p.items.isEmpty)
    }

    @Test func aFolderNeverMovesIntoItself() {
        var p = SidebarProfile(name: "Primary")
        let outer = p.addFolder("Outer")
        let inner = p.addFolder("Inner", in: outer)
        p.move(outer, into: inner)
        p.move(outer, into: outer)
        #expect(p.items.count == 1 && p.items[0].id == outer)
        p.move(inner, into: nil)
        #expect(p.items.map(\.id) == [outer, inner])
    }

    /// Review F1: an id that isn't a folder (deleted by a sync, or a link's id)
    /// must never lose the item being moved or saved.
    @Test func nothingIsLostIntoAFolderThatIsntThere() {
        var p = SidebarProfile(name: "Primary")
        let link = SavedLink(title: "Keep", url: "https://keep.example/")
        p.addLink(link)
        p.move(link.id, into: UUID()) // a folder that no longer exists
        #expect(p.allLinks.map(\.title) == ["Keep"])
        let other = SavedLink(title: "Other", url: "https://other.example/")
        p.addLink(other)
        p.move(link.id, into: other.id) // a link, not a folder
        #expect(p.allLinks.count == 2)
        p.addLink(SavedLink(title: "Saved", url: "https://saved.example/"), in: UUID())
        #expect(p.allLinks.map(\.title).contains("Saved")) // lands at the top level instead
    }

    @Test func favoritesDoNotRepeat() {
        var p = SidebarProfile(name: "Primary")
        p.addFavorite(SavedLink(title: "Mail", url: "https://mail.example/"))
        p.addFavorite(SavedLink(title: "Mail again", url: "https://MAIL.example"))
        #expect(p.favorites.count == 1)
    }

    @Test func aSavedLinkMatchesItsOpenTabDespiteFragmentsAndSlashes() {
        #expect(SavedLink.same("https://Example.com/docs/", "https://example.com/docs#intro"))
        #expect(SavedLink.same("https://example.com", "https://example.com/"))
        #expect(!SavedLink.same("https://example.com/a", "https://example.com/b"))
        #expect(!SavedLink.same("https://example.com/?q=1", "https://example.com/?q=2"))
    }

    @Test func aProfilesFrameColorIsReadFromLocalState() {
        // Values from Chrome on the Mac mini: the "Claude" profile's dark orange frame.
        let json = #"{"profile":{"info_cache":{"Profile 1":{"name":"Claude","profile_highlight_color":-13690100}},"Default":{}}}"#
        #expect(ProfileCatalog.frameColor(localStateJSON: Data(json.utf8), directory: "Profile 1") == 0x2F1B0C)
        #expect(ProfileCatalog.frameColor(localStateJSON: Data(json.utf8), directory: "Default") == nil)
    }

    @Test func aCustomColorThemeIsReadFromPreferences() {
        // The "Your Chrome" profile on the Mac mini: a red custom color.
        let themed = #"{"extensions":{"theme":{"id":"autogenerated_theme_id"}},"autogenerated":{"theme":{"color":-4776932}}}"#
        #expect(ProfileCatalog.themeColor(preferencesJSON: Data(themed.utf8)) == 0xB71C1C)
        let other = #"{"extensions":{"theme":{"id":"user_color_theme_id"}},"autogenerated":{"theme":{"color":-4776932}}}"#
        #expect(ProfileCatalog.themeColor(preferencesJSON: Data(other.utf8)) == nil)
    }

    @Test func theStoreStartsWithPrimaryAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bl-sb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SidebarStore(file: dir.appendingPathComponent("sidebar.json"))
        #expect(try store.load().profiles.map(\.name) == ["Primary"])
        let saved = try store.update { lib in
            lib.update(lib.profiles[0].id) { $0.addFolder("Travel") }
            lib.profiles.append(SidebarProfile(name: "Work", browserProfiles: [chromeClaude]))
        }
        #expect(try store.load() == saved)
        let attrs = try FileManager.default.attributesOfItem(atPath: store.file.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
