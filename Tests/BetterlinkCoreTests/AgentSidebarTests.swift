import Foundation
import Testing
@testable import BetterlinkCore

/// The sidebar agent commands: everything the sidebar's menus and drags do to
/// saved things, from the command line.
struct AgentSidebarTests {
    func folder() throws -> SettingsFolder {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bl-sidebar-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return SettingsFolder(directory: d)
    }

    func call(_ command: String, _ input: [String: Any] = [:], in f: SettingsFolder) -> (ok: Bool, data: Any?, error: String?) {
        let env = AgentEnvironment(folder: f, installed: [Browser.known(bundleId: "com.google.Chrome")!])
        let r = Agent.run(command, input: input, env: env)
        return (r.ok, r.data, r.error)
    }

    func lib(_ f: SettingsFolder) throws -> SidebarLibrary { try SidebarStore(folder: f).load() }

    @Test func everySidebarCommandIsListed() {
        for c in Agent.sidebarCommands { #expect(Agent.commands.contains(c)) }
    }

    @Test func listShowsTheStarterProfile() throws {
        let f = try folder()
        let r = call("sidebar.list", in: f)
        #expect(r.ok)
        let profiles = try #require(r.data as? [[String: Any]])
        #expect(profiles.map { $0["name"] as? String } == ["Primary"])
    }

    @Test func profilesAreAddedRenamedAssignedAndRemoved() throws {
        let f = try folder()
        #expect(call("sidebar.profiles.add", ["name": "Work"], in: f).ok)
        #expect(call("sidebar.profiles.rename", ["profile": "work", "name": "Job"], in: f).ok)
        #expect(try lib(f).profiles.map(\.name) == ["Primary", "Job"])
        #expect(call("sidebar.profiles.assign", ["profile": "Job", "browser": "Google Chrome", "browserProfile": "Profile 1"], in: f).ok)
        let ref = ProfileRef(browser: "com.google.Chrome", directory: "Profile 1")
        #expect(try lib(f).profile(for: ref)?.name == "Job")
        #expect(call("sidebar.profiles.unassign", ["browser": "com.google.Chrome", "browserProfile": "Profile 1"], in: f).ok)
        #expect(try lib(f).profile(for: ref)?.name == "Primary")
        #expect(call("sidebar.profiles.remove", ["profile": "Job"], in: f).ok)
        let last = call("sidebar.profiles.remove", ["profile": "Primary"], in: f)
        #expect(!last.ok && last.error!.contains("only Sidebar Profile"))
    }

    @Test func profileMustBeNamedWhenThereAreSeveral() throws {
        let f = try folder()
        _ = call("sidebar.profiles.add", ["name": "Work"], in: f)
        let r = call("sidebar.links.add", ["url": "https://example.com"], in: f)
        #expect(!r.ok && r.error!.contains("Give profile"))
    }

    @Test func foldersLinksAndFavoritesAreMadeWhereAsked() throws {
        let f = try folder()
        let folderID = try #require((call("sidebar.folders.add", ["name": "Reading"], in: f).data as? [String: Any])?["id"] as? String)
        #expect(call("sidebar.links.add", ["url": "https://a.example", "title": "A", "to": folderID], in: f).ok)
        #expect(call("sidebar.links.add", ["url": "https://b.example", "to": String(folderID.prefix(6)), "position": 1], in: f).ok)
        #expect(call("sidebar.links.add", ["url": "https://mail.example", "to": "favorites"], in: f).ok)
        let p = try lib(f).profiles[0]
        #expect(p.favorites.map(\.url) == ["https://mail.example"])
        guard case .folder(let reading) = p.items.first else { Issue.record("no folder"); return }
        #expect(SidebarProfile.links(in: reading.items).map(\.url) == ["https://b.example", "https://a.example"])
        // The same address twice in Favorites is refused, as a drop is.
        #expect(!call("sidebar.links.add", ["url": "https://mail.example", "to": "favorites"], in: f).ok)
        // Not a web address.
        #expect(!call("sidebar.links.add", ["url": "javascript:alert(1)"], in: f).ok)
    }

    @Test func itemsAreRenamedRepointedMovedAndRemoved() throws {
        let f = try folder()
        let fid = try #require((call("sidebar.folders.add", ["name": "Docs"], in: f).data as? [String: Any])?["id"] as? String)
        let lid = try #require((call("sidebar.links.add", ["url": "https://old.example"], in: f).data as? [String: Any])?["id"] as? String)
        #expect(call("sidebar.items.update", ["id": lid, "url": "https://new.example", "title": "New"], in: f).ok)
        #expect(call("sidebar.items.update", ["id": fid, "name": "Papers"], in: f).ok)
        #expect(!call("sidebar.items.update", ["id": fid, "url": "https://x.example"], in: f).ok)
        // Into the folder, then into Favorites, then back to the top.
        #expect(call("sidebar.items.move", ["id": lid, "to": fid], in: f).ok)
        #expect(try lib(f).profiles[0].parent(of: UUID(uuidString: lid)!) == UUID(uuidString: fid))
        #expect(call("sidebar.items.move", ["id": lid, "to": "favorites"], in: f).ok)
        #expect(try lib(f).profiles[0].favorites.map(\.title) == ["New"])
        #expect(!call("sidebar.items.move", ["id": fid, "to": "favorites"], in: f).ok) // a folder can't be a favorite
        #expect(!call("sidebar.items.move", ["id": fid, "to": fid], in: f).ok)         // nor go inside itself
        #expect(call("sidebar.items.move", ["id": lid, "to": "top", "position": 1], in: f).ok)
        #expect(try lib(f).profiles[0].items.first?.id == UUID(uuidString: lid))
        // A folder with things in it needs withContents.
        _ = call("sidebar.items.move", ["id": lid, "to": fid], in: f)
        #expect(!call("sidebar.items.remove", ["id": fid], in: f).ok)
        #expect(call("sidebar.items.remove", ["id": fid, "withContents": true], in: f).ok)
        #expect(try lib(f).profiles[0].allLinks.isEmpty)
    }

    @Test func aReorderInPlaceNeedsOnlyAPosition() throws {
        let f = try folder()
        for u in ["https://1.example", "https://2.example", "https://3.example"] { _ = call("sidebar.links.add", ["url": u, "to": "favorites"], in: f) }
        let third = try lib(f).profiles[0].favorites[2].id.uuidString
        #expect(call("sidebar.items.move", ["id": third, "position": 1], in: f).ok)
        #expect(try lib(f).profiles[0].favorites.map(\.url) == ["https://3.example", "https://1.example", "https://2.example"])
    }

    @Test func foldersOpenAndClose() throws {
        let f = try folder()
        let fid = try #require((call("sidebar.folders.add", ["name": "F"], in: f).data as? [String: Any])?["id"] as? String)
        #expect(call("sidebar.items.expand", ["id": fid, "expanded": false], in: f).ok)
        guard case .folder(let closed) = try lib(f).profiles[0].items[0] else { return }
        #expect(!closed.expanded)
        #expect(call("sidebar.items.expand", ["id": fid, "expanded": false], in: f).ok) // already closed: stays closed
        guard case .folder(let still) = try lib(f).profiles[0].items[0] else { return }
        #expect(!still.expanded)
    }

    @Test func everyFolderOpensOrClosesAtOnce() throws {
        let f = try folder()
        let a = try #require((call("sidebar.folders.add", ["name": "A"], in: f).data as? [String: Any])?["id"] as? String)
        _ = call("sidebar.folders.add", ["name": "Inner", "to": a], in: f)
        _ = call("sidebar.folders.add", ["name": "B"], in: f)
        func open() throws -> [Bool] {
            func walk(_ items: [SidebarItem]) -> [Bool] {
                items.flatMap { item -> [Bool] in
                    if case .folder(let x) = item { return [x.expanded] + walk(x.items) }
                    return []
                }
            }
            return walk(try lib(f).profiles[0].items)
        }
        #expect(call("sidebar.items.expand", ["all": true, "expanded": false], in: f).ok)
        #expect(try open() == [false, false, false])
        #expect(call("sidebar.items.expand", ["all": true, "expanded": true], in: f).ok)
        #expect(try open() == [true, true, true])
        #expect(!call("sidebar.items.expand", ["all": true, "id": a, "expanded": false], in: f).ok) // one or the other
        #expect(!call("sidebar.items.expand", ["all": true], in: f).ok) // which way
        #expect(try open() == [true, true, true])
    }

    // MARK: Folder icons

    @Test func aFolderGetsAnEmojiOrASymbolAndLosesIt() throws {
        let f = try folder()
        let fid = try #require((call("sidebar.folders.add", ["name": "Docs"], in: f).data as? [String: Any])?["id"] as? String)
        let r = call("sidebar.folders.icon", ["id": String(fid.prefix(6)), "emoji": "🚀"], in: f)
        #expect(r.ok, "\(r.error ?? "")")
        #expect(try lib(f).profiles[0].folder(UUID(uuidString: fid)!)?.icon == .emoji("🚀"))
        // The answer is the Sidebar Profile, with the icon on the folder.
        let items = try #require((r.data as? [String: Any])?["items"] as? [[String: Any]])
        #expect(items.first?["icon"] as? [String: String] == ["emoji": "🚀"])

        #expect(call("sidebar.folders.icon", ["id": fid, "symbol": "star.fill"], in: f).ok)
        #expect(try lib(f).profiles[0].folder(UUID(uuidString: fid)!)?.icon == .symbol("star.fill"))

        #expect(call("sidebar.folders.icon", ["id": fid, "clear": true], in: f).ok)
        #expect(try lib(f).profiles[0].folder(UUID(uuidString: fid)!)?.icon == nil)
    }

    @Test func theListingShowsAFoldersIconAndLeavesItOutWhenThereIsNone() throws {
        let f = try folder()
        let a = try #require((call("sidebar.folders.add", ["name": "A"], in: f).data as? [String: Any])?["id"] as? String)
        _ = call("sidebar.folders.add", ["name": "B"], in: f)
        _ = call("sidebar.folders.icon", ["id": a, "symbol": "star.fill"], in: f)
        let items = try #require((call("sidebar.list", in: f).data as? [[String: Any]])?.first?["items"] as? [[String: Any]])
        #expect(items[0]["icon"] as? [String: String] == ["symbol": "star.fill"])
        #expect(items[1]["icon"] == nil)
    }

    @Test func folderIconsRefuseWhatTheyCantShow() throws {
        let f = try folder()
        let fid = try #require((call("sidebar.folders.add", ["name": "Docs"], in: f).data as? [String: Any])?["id"] as? String)
        let lid = try #require((call("sidebar.links.add", ["url": "https://a.example"], in: f).data as? [String: Any])?["id"] as? String)
        func refused(_ input: [String: Any], _ says: String) {
            let r = call("sidebar.folders.icon", input, in: f)
            #expect(!r.ok && r.error?.contains(says) == true, "\(input): \(r.error ?? "accepted")")
        }
        refused(["id": lid, "emoji": "🚀"], "folder")                       // a saved link shows its site's icon
        refused(["id": fid], "Give emoji")                                  // nothing to set
        refused(["id": fid, "emoji": "🚀", "symbol": "star.fill"], "one of") // two at once
        refused(["id": fid, "emoji": "🚀", "clear": true], "one of")
        refused(["id": fid, "emoji": "ab"], "one emoji")
        refused(["id": fid, "emoji": "a"], "isn't an emoji")
        refused(["id": fid, "symbol": "star fill"], "isn't a symbol name")
        refused(["id": fid, "clear": "yes"], "true or false")
        #expect(try lib(f).profiles[0].folder(UUID(uuidString: fid)!)?.icon == nil)
    }

    /// In the app the symbol is checked against the Mac's own symbols.
    @Test func aSymbolTheMacLacksIsRefused() throws {
        let f = try folder()
        let fid = try #require((call("sidebar.folders.add", ["name": "Docs"], in: f).data as? [String: Any])?["id"] as? String)
        let env = AgentEnvironment(folder: f, installed: [], symbolExists: { $0 == "star.fill" })
        #expect(Agent.run("sidebar.folders.icon", input: ["id": fid, "symbol": "star.fill"], env: env).ok)
        let r = Agent.run("sidebar.folders.icon", input: ["id": fid, "symbol": "star.sparkly"], env: env)
        #expect(!r.ok && r.error?.contains("no symbol called") == true)
        #expect(try lib(f).profiles[0].folder(UUID(uuidString: fid)!)?.icon == .symbol("star.fill"))
    }

    @Test func idPrefixesMustBeUniqueAndLongEnough() throws {
        let f = try folder()
        let lid = try #require((call("sidebar.links.add", ["url": "https://a.example"], in: f).data as? [String: Any])?["id"] as? String)
        #expect(!call("sidebar.items.remove", ["id": String(lid.prefix(3))], in: f).ok)
        #expect(call("sidebar.items.remove", ["id": String(lid.prefix(8)).lowercased()], in: f).ok)
    }

    @Test func bookmarksImportFromAFileGoesIntoOneClosedFolder() throws {
        let f = try folder()
        let html = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1><DL><p>
        <DT><A HREF="https://a.example">A</A>
        <DT><H3>Sub</H3><DL><p><DT><A HREF="https://b.example">B</A></DL><p>
        </DL><p>
        """
        let file = f.directory.appendingPathComponent("bookmarks.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        let r = call("sidebar.import", ["from": "file", "path": file.path], in: f)
        #expect(r.ok, "\(r.error ?? "")")
        let p = try lib(f).profiles[0]
        guard case .folder(let imported) = p.items.first else { Issue.record("no folder"); return }
        #expect(imported.name == "Bookmarks" && !imported.expanded)
        #expect(Set(SidebarProfile.links(in: imported.items).map(\.url)) == ["https://a.example", "https://b.example"])
        #expect(!call("sidebar.import", ["from": "nowhere"], in: f).ok)
    }

    // MARK: Review round 1

    @Test func closeOthersSparesSavedLinksTabsAndHeldTabs() {
        var p = SidebarProfile(name: "P")
        p.addFavorite(SavedLink(title: "Mail", url: "https://mail.example.com/"))
        p.addLink(SavedLink(title: "Docs", url: "https://docs.example.com/start"))
        let lib = SidebarLibrary(profiles: [p])
        let tabs: [(id: Int, url: String)] = [
            (1, "https://mail.example.com"),          // a Favorite's page (trailing slash aside)
            (2, "https://docs.example.com/start"),    // a saved link's page
            (3, "https://news.example.com/today"),    // a held tab that navigated away
            (4, "https://random.example.com"),        // nobody's
        ]
        // The app remembers held tabs by address (HoldLedger.remembered), not by tab id.
        let remembered: [String: [String: [String]]] = ["profile-key": [UUID().uuidString: ["https://news.example.com/today"]]]
        #expect(Agent.sparedTabs(tabs, library: lib, remembered: remembered) == [1, 2, 3])
    }

    @Test func theStarterProfileKeepsItsIdBetweenCalls() throws {
        let f = try folder()
        // Each CLI call is a new process, where the unsaved starter would get a
        // new id; the id listed must be the one saved in sidebar.json.
        let first = try #require((call("sidebar.list", in: f).data as? [[String: Any]])?.first?["id"] as? String)
        let saved = f.directory.appendingPathComponent("sidebar.json")
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(try SidebarStore(folder: f).load().profiles.first?.id.uuidString == first)
        #expect(call("sidebar.folders.add", ["profile": first, "name": "F"], in: f).ok)
        // A file with an empty profile list is the same case.
        try #"{"version":1,"profiles":[]}"#.write(to: saved, atomically: true, encoding: .utf8)
        let again = try #require((call("sidebar.list", in: f).data as? [[String: Any]])?.first?["id"] as? String)
        #expect(try SidebarStore(folder: f).load().profiles.first?.id.uuidString == again)
    }

    // MARK: Several at once

    /// A profile with links A, B, C at the top level and folder F holding X.
    func several(_ f: SettingsFolder) throws -> (a: String, b: String, c: String, folder: String, x: String) {
        func id(_ r: (ok: Bool, data: Any?, error: String?)) throws -> String {
            try #require((r.data as? [String: Any])?["id"] as? String)
        }
        let a = try id(call("sidebar.links.add", ["url": "https://a.example", "title": "A"], in: f))
        let b = try id(call("sidebar.links.add", ["url": "https://b.example", "title": "B"], in: f))
        let c = try id(call("sidebar.links.add", ["url": "https://c.example", "title": "C"], in: f))
        let folder = try id(call("sidebar.folders.add", ["name": "F"], in: f))
        let x = try id(call("sidebar.links.add", ["url": "https://x.example", "title": "X", "to": folder], in: f))
        return (a, b, c, folder, x)
    }

    func names(_ items: [SidebarItem]) -> [String] {
        items.map { item in
            switch item {
            case .link(let l): return l.title
            case .folder(let f): return f.name + "[" + names(f.items).joined(separator: ",") + "]"
            }
        }
    }

    @Test func severalMoveTogetherInTheOrderGiven() throws {
        let f = try folder()
        let s = try several(f)
        #expect(call("sidebar.items.move", ["ids": [s.c, s.a], "to": s.folder, "position": 1], in: f).ok)
        #expect(names(try lib(f).profiles[0].items) == ["B", "F[C,A,X]"])
        // Starts of ids work in a list too, and `id` counts as one more.
        #expect(call("sidebar.items.move", ["ids": [String(s.x.prefix(8))], "id": s.b, "to": "favorites"], in: f).ok)
        #expect(try lib(f).profiles[0].favorites.map(\.title) == ["X", "B"])
    }

    @Test func severalMoveAllOrNone() throws {
        let f = try folder()
        let s = try several(f)
        let before = try lib(f)
        // A folder can't be a favorite, so nothing moves.
        let r = call("sidebar.items.move", ["ids": [s.a, s.folder], "to": "favorites"], in: f)
        #expect(!r.ok && r.error!.contains("Nothing was moved"))
        #expect(try lib(f) == before)
        // Several need a place to go.
        #expect(!call("sidebar.items.move", ["ids": [s.a, s.b], "position": 1], in: f).ok)
        #expect(!call("sidebar.items.move", ["ids": [s.a, "nope-nope"], "to": "top"], in: f).ok)
        #expect(!call("sidebar.items.move", ["ids": "not a list", "to": "top"], in: f).ok)
        #expect(try lib(f) == before)
    }

    @Test func severalAreRemovedTogether() throws {
        let f = try folder()
        let s = try several(f)
        let full = call("sidebar.items.remove", ["ids": [s.a, s.folder]], in: f)
        #expect(!full.ok && full.error!.contains("isn't empty"))
        #expect(names(try lib(f).profiles[0].items) == ["A", "B", "C", "F[X]"])
        // X goes with its folder, named or not.
        #expect(call("sidebar.items.remove", ["ids": [s.a, s.folder, s.x], "withContents": true], in: f).ok)
        #expect(names(try lib(f).profiles[0].items) == ["B", "C"])
    }

    @Test func aNewFolderTakesThingsWithIt() throws {
        let f = try folder()
        let s = try several(f)
        // It stands where the first of them stood.
        let r = call("sidebar.folders.add", ["name": "New", "with": [s.b, s.x]], in: f)
        #expect(r.ok)
        #expect((r.data as? [String: Any])?["id"] is String)
        #expect(names(try lib(f).profiles[0].items) == ["A", "New[B,X]", "C", "F[]"])
        // Or where it is asked to go.
        #expect(call("sidebar.folders.add", ["name": "Top", "with": [s.a, s.c], "to": "top", "position": 1], in: f).ok)
        #expect(names(try lib(f).profiles[0].items) == ["Top[A,C]", "New[B,X]", "F[]"])
        // Not inside a folder it takes.
        let before = try lib(f)
        let inside = call("sidebar.folders.add", ["name": "Loop", "with": [s.folder], "to": s.folder], in: f)
        #expect(!inside.ok && inside.error!.contains("inside itself"))
        #expect(try lib(f) == before)
    }

    @Test func openTabsAreSavedWhereAsked() throws {
        let f = try folder()
        let s = try several(f)
        let env = AgentEnvironment(folder: f, installed: [])
        // New links each time, as the app makes them from the open tabs.
        func tabs() -> [SavedLink] {
            [SavedLink(title: "One", url: "https://one.example"), SavedLink(title: "Two", url: "https://two.example")]
        }
        // Into a folder, at the top of it.
        let into = Agent.saveTabs(tabs(), ["to": s.folder, "position": 1], env)
        #expect(into.ok)
        #expect(((into.data as? [String: Any])?["saved"] as? [String])?.count == 2)
        #expect(names(try lib(f).profiles[0].items) == ["A", "B", "C", "F[One,Two,X]"])
        // Into a new folder.
        let made = Agent.saveTabs(tabs(), ["folder": "Later"], env)
        #expect(made.ok && (made.data as? [String: Any])?["folder"] is String)
        #expect(names(try lib(f).profiles[0].items).last == "Later[One,Two]")
        // Favorites take an address once.
        #expect(Agent.saveTabs(tabs(), ["to": "favorites"], env).ok)
        let third = SavedLink(title: "Three", url: "https://three.example")
        let again = Agent.saveTabs([tabs()[0], third], ["to": "favorites"], env)
        #expect(again.ok)
        #expect((again.data as? [String: Any])?["alreadyFavorites"] as? [String] == ["https://one.example"])
        #expect(try lib(f).profiles[0].favorites.map(\.title) == ["One", "Two", "Three"])
        let none = Agent.saveTabs([tabs()[0]], ["to": "favorites"], env)
        #expect(!none.ok && none.error!.contains("already have"))
        #expect(!Agent.saveTabs(tabs(), ["to": "favorites", "folder": "No"], env).ok)
        #expect(!Agent.saveTabs([], [:], env).ok)
    }
}
