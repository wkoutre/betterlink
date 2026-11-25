import Foundation
import Testing
@testable import BetterlinkCore

struct SidebarImportTests {
    /// The shape of Arc's StorableSidebar.json: Swift's encoding, so every
    /// dictionary is a flat `key, value` array and every enum a one-key object.
    /// A standalone window's pair comes first here, as it can in real files.
    static let arc = #"""
    {
      "version" : 1,
      "sidebar" : { "containers" : [
        { "standalone" : { "_0" : "6A1F" } },
        { "spaces" : [ ], "items" : [ "S1", { "id" : "S1", "parentID" : null, "childrenIds" : [ ], "title" : null,
            "data" : { "tab" : { "savedURL" : "https:\/\/standalone.example\/", "savedTitle" : "Not in the sidebar" } } } ],
          "topAppsContainerIDs" : [ ] },
        { "global" : { } },
        {
          "topAppsContainerIDs" : [ { "default" : true }, "FAV-DEFAULT",
                                    { "custom" : { "_0" : { "directoryBasename" : "Profile 1", "machineID" : "M" } } }, "FAV-WORK" ],
          "spaces" : [
            "thebrowser.company.defaultPersonalSpaceID",
            { "id" : "thebrowser.company.defaultPersonalSpaceID", "title" : "Personal", "profile" : { "default" : true },
              "containerIDs" : [ "unpinned", "P-TODAY", "pinned", "P-PINNED" ],
              "newContainerIDs" : [ { "pinned" : { } }, "P-PINNED", { "unpinned" : { "_0" : { "shared" : { } } } }, "P-TODAY" ] },
            "SPACE-WORK",
            { "id" : "SPACE-WORK", "title" : "Work",
              "profile" : { "custom" : { "_0" : { "directoryBasename" : "Profile 1", "machineID" : "M" } } },
              "newContainerIDs" : [ { "unpinned" : { "_0" : { "shared" : { } } } }, "W-TODAY", { "pinned" : { } }, "W-PINNED" ] },
            "SPACE-EMPTY",
            { "id" : "SPACE-EMPTY", "profile" : { "default" : { } },
              "containerIDs" : [ "pinned", "E-PINNED", "unpinned", "E-TODAY" ] }
          ],
          "items" : [
            "FAV-DEFAULT", { "id" : "FAV-DEFAULT", "parentID" : null, "childrenIds" : [ "F1", "F2" ], "title" : null,
              "data" : { "itemContainer" : { "containerType" : { "topApps" : { "_0" : { "default" : true } } } } } },
            "F1", { "id" : "F1", "parentID" : "FAV-DEFAULT", "childrenIds" : [ ], "title" : null,
              "data" : { "tab" : { "savedURL" : "https:\/\/mail.example\/", "savedTitle" : "Mail" } } },
            "F2", { "id" : "F2", "parentID" : "FAV-DEFAULT", "childrenIds" : [ ], "title" : "Cal",
              "data" : { "tab" : { "savedURL" : "https:\/\/calendar.example\/", "savedTitle" : "Calendar - Week" } } },
            "FAV-WORK", { "id" : "FAV-WORK", "parentID" : null, "childrenIds" : [ "F3" ], "title" : null,
              "data" : { "itemContainer" : { "containerType" : { "topApps" : { "_0" : { } } } } } },
            "F3", { "id" : "F3", "parentID" : "FAV-WORK", "childrenIds" : [ ], "title" : null,
              "data" : { "tab" : { "savedURL" : "https:\/\/tracker.example\/", "savedTitle" : "Tracker" } } },

            "P-PINNED", { "id" : "P-PINNED", "parentID" : null, "childrenIds" : [ "T2", "FOLDER", "SPLIT", "EASEL", "T-INTERNAL", "GHOST" ], "title" : null,
              "data" : { "itemContainer" : { "containerType" : { "spaceItems" : { "_0" : "thebrowser.company.defaultPersonalSpaceID" } } } } },
            "T2", { "id" : "T2", "parentID" : "P-PINNED", "childrenIds" : [ ], "title" : "",
              "data" : { "tab" : { "savedURL" : "https:\/\/news.example\/front", "savedTitle" : "News" } } },
            "FOLDER", { "id" : "FOLDER", "parentID" : "P-PINNED", "childrenIds" : [ "T3", "INNER" ], "title" : "Trips", "data" : { "list" : { } } },
            "T3", { "id" : "T3", "parentID" : "FOLDER", "childrenIds" : [ ], "title" : "Flights",
              "data" : { "tab" : { "savedURL" : "https:\/\/air.example\/", "savedTitle" : "Air - Book flights" } } },
            "INNER", { "id" : "INNER", "parentID" : "FOLDER", "childrenIds" : [ "T4", "FOLDER" ], "title" : null, "data" : { "list" : { } } },
            "T4", { "id" : "T4", "parentID" : "INNER", "childrenIds" : [ ], "title" : null,
              "data" : { "tab" : { "savedURL" : "https:\/\/hotel.example\/", "savedTitle" : "" } } },
            "SPLIT", { "id" : "SPLIT", "parentID" : "P-PINNED", "childrenIds" : [ "T5", "T6" ], "title" : null, "data" : { "splitView" : { } } },
            "T5", { "id" : "T5", "parentID" : "SPLIT", "childrenIds" : [ ], "title" : null,
              "data" : { "tab" : { "savedURL" : "https:\/\/left.example\/", "savedTitle" : "Left" } } },
            "T6", { "id" : "T6", "parentID" : "SPLIT", "childrenIds" : [ ], "title" : null,
              "data" : { "tab" : { "savedURL" : "https:\/\/right.example\/", "savedTitle" : "Right" } } },
            "EASEL", { "id" : "EASEL", "parentID" : "P-PINNED", "childrenIds" : [ ], "title" : "Board", "data" : { "easel" : { "easelID" : "E" } } },
            "T-INTERNAL", { "id" : "T-INTERNAL", "parentID" : "P-PINNED", "childrenIds" : [ ], "title" : null,
              "data" : { "tab" : { "savedURL" : "chrome:\/\/settings\/", "savedTitle" : "Settings" } } },

            "P-TODAY", { "id" : "P-TODAY", "parentID" : null, "childrenIds" : [ "T1" ], "title" : null,
              "data" : { "itemContainer" : { "containerType" : { "spaceItems" : { "_0" : "thebrowser.company.defaultPersonalSpaceID" } } } } },
            "T1", { "id" : "T1", "parentID" : "P-TODAY", "childrenIds" : [ ], "title" : null,
              "data" : { "tab" : { "savedURL" : "https:\/\/today.example\/", "savedTitle" : "Only open today" } } },

            "W-PINNED", { "id" : "W-PINNED", "parentID" : null, "childrenIds" : [ "T7" ], "title" : null,
              "data" : { "itemContainer" : { "containerType" : { "spaceItems" : { "_0" : "SPACE-WORK" } } } } },
            "T7", { "id" : "T7", "parentID" : "W-PINNED", "childrenIds" : [ ], "title" : null,
              "data" : { "tab" : { "savedURL" : "https:\/\/docs.example\/", "savedTitle" : "Docs" } } },
            "E-PINNED", { "id" : "E-PINNED", "parentID" : null, "childrenIds" : [ ], "title" : null,
              "data" : { "itemContainer" : { "containerType" : { "spaceItems" : { "_0" : "SPACE-EMPTY" } } } } }
          ]
        }
      ] }
    }
    """#

    func names(_ items: [SidebarItem]) -> [String] {
        items.map { item in
            switch item {
            case .link(let l): return l.title
            case .folder(let f): return "[\(f.name): \(names(f.items).joined(separator: ", "))]"
            }
        }
    }

    @Test func eachArcSpaceComesInWithItsPinnedTabsFoldersAndItsProfilesFavorites() throws {
        let spaces = try SidebarImport.arc(Data(Self.arc.utf8))
        #expect(spaces.map(\.name) == ["Personal", "Work", "Space 3"])

        let personal = spaces[0]
        #expect(personal.favorites.map(\.title) == ["Mail", "Cal"])
        #expect(personal.favorites.map(\.url) == ["https://mail.example/", "https://calendar.example/"])
        // Pinned only, in Arc's order: Today's tabs, the easel, the internal
        // page and the missing item are left out; the split view is its two tabs;
        // the folder that lists its own parent doesn't loop.
        #expect(names(personal.items) == ["News", "[Trips: Flights, [Folder: https://hotel.example/]]", "Left", "Right"])
        #expect(personal.linkCount == 7)

        let work = spaces[1]
        #expect(work.favorites.map(\.title) == ["Tracker"], "a Space gets the Favorites of its own profile")
        #expect(names(work.items) == ["Docs"])

        // The third Space shares the default profile's Favorites and has nothing pinned.
        #expect(spaces[2].favorites.map(\.title) == ["Mail", "Cal"])
        #expect(spaces[2].items.isEmpty)
        // Shared Favorites are separate saved links, not the same ids twice.
        #expect(Set(spaces[0].favorites.map(\.id)).isDisjoint(with: spaces[2].favorites.map(\.id)))
    }

    @Test func importedArcFoldersStartClosed() throws {
        let spaces = try SidebarImport.arc(Data(Self.arc.utf8))
        guard case .folder(let trips) = spaces[0].items[1] else { Issue.record("no folder"); return }
        #expect(!trips.expanded)
    }

    @Test func aFileThatIsNotArcsIsRefused() {
        #expect(throws: SidebarImportError.notArc) { try SidebarImport.arc(Data("{}".utf8)) }
        #expect(throws: SidebarImportError.notArc) { try SidebarImport.arc(Data("not json".utf8)) }
        #expect(throws: SidebarImportError.notArc) {
            try SidebarImport.arc(Data(#"{"sidebar":{"containers":[{"global":{}},{"items":[],"spaces":[]}]}}"#.utf8))
        }
    }

    @Test func anArcFileWithoutTheGlobalMarkerStillFindsItsSidebar() throws {
        let json = #"{"sidebar":{"containers":[{"spaces":["A",{"id":"A","title":"Solo","containerIDs":["pinned","P"]}],"items":["P",{"id":"P","childrenIds":["T"],"data":{"itemContainer":{}}},"T",{"id":"T","childrenIds":[],"title":null,"data":{"tab":{"savedURL":"https://solo.example/","savedTitle":"Solo page"}}}]}]}}"#
        let spaces = try SidebarImport.arc(Data(json.utf8))
        #expect(spaces.count == 1)
        #expect(names(spaces[0].items) == ["Solo page"])
        #expect(spaces[0].favorites.isEmpty)
    }

    @Test func chromiumBookmarksKeepTheirFoldersAndOnlyWebAddresses() throws {
        let json = #"""
        { "checksum": "x", "version": 1, "roots": {
          "bookmark_bar": { "type": "folder", "name": "Bookmarks bar", "children": [
            { "type": "url", "name": "Mail", "url": "https://mail.example/" },
            { "type": "folder", "name": "Read", "children": [
              { "type": "url", "name": "", "url": "https://blog.example/post" },
              { "type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)" },
              { "type": "folder", "name": "", "children": [] } ] },
            { "type": "url", "name": "Flags", "url": "chrome://flags/" } ] },
          "other": { "type": "folder", "name": "Other bookmarks", "children": [
            { "type": "url", "name": "Later", "url": "http://later.example/" } ] },
          "synced": { "type": "folder", "name": "Mobile bookmarks", "children": [] } } }
        """#
        let b = try SidebarImport.chromiumBookmarks(Data(json.utf8))
        #expect(names(b.items) == ["Mail", "[Read: https://blog.example/post, [Folder: ]]", "[Other Bookmarks: Later]"])
        #expect(b.favorites.isEmpty)
        #expect(b.linkCount == 3)
        #expect(throws: SidebarImportError.notBookmarks) { try SidebarImport.chromiumBookmarks(Data("[]".utf8)) }
    }

    @Test func aBookmarksHTMLExportKeepsFoldersNamesAndInlineIcons() {
        let html = #"""
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <TITLE>Bookmarks</TITLE>
        <H1>Bookmarks</H1>
        <DL><p>
            <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
            <DL><p>
                <DT><A HREF="https://mail.example/?a=1&amp;b=2" ADD_DATE="2" ICON="data:image/png;base64,AAAA">Mail &amp; Calendar</A>
                <DT><H3>R&#233;sum&#xE9;s &lt;2026&gt;</H3>
                <DL><p>
                    <DT><a href="https://cv.example/">CV</a>
                    <DT><A HREF="javascript:void(0)">Bookmarklet</A>
                    <DT><A HREF="place:sort=8">Most Visited</A>
                </DL><p>
            </DL><p>
            <DT><A HREF="http://loose.example/" ICON="https://loose.example/favicon.ico"></A>
        </DL><p>
        """#
        let b = SidebarImport.bookmarksHTML(html)
        #expect(names(b.items) == ["[Bookmarks bar: Mail & Calendar, [Résumés <2026>: CV]]", "http://loose.example/"])
        let links = SidebarProfile.links(in: b.items)
        #expect(links[0].url == "https://mail.example/?a=1&b=2")
        #expect(links[0].icon == "data:image/png;base64,AAAA")
        #expect(links[2].icon == nil, "a remote icon address is never kept: betterlink fetches nothing")
        #expect(SidebarImport.bookmarksHTML("").isEmpty)
        #expect(SidebarImport.bookmarksHTML("<DL><DT><A HREF=\"https://open.example/\">Never closed</A>").linkCount == 1)
    }

    @Test func anImportIsCappedSoAHugeFileCannotSwellTheSidebar() {
        let many = (0..<(SidebarImport.limit + 50)).map { "<DT><A HREF=\"https://s\($0).example/\">S\($0)</A>" }.joined(separator: "\n")
        #expect(SidebarImport.bookmarksHTML("<DL>\(many)</DL>").linkCount == SidebarImport.limit)
    }

    @Test func bookmarksLandInAClosedFolderAndFavoritesAreNotDoubled() {
        var p = SidebarProfile(name: "Primary")
        p.addFavorite(SavedLink(title: "Mail", url: "https://mail.example/"))
        p.addLink(SavedLink(title: "Mine", url: "https://mine.example/"))
        let imp = ImportedSidebar(name: "Bookmarks",
                                  favorites: [SavedLink(title: "Mail again", url: "https://mail.example"), SavedLink(title: "Cal", url: "https://cal.example/")],
                                  items: [.link(SavedLink(title: "A", url: "https://a.example/"))])
        p.add(imp, inFolder: "Chrome Bookmarks")
        #expect(p.favorites.map(\.title) == ["Mail", "Cal"])
        #expect(names(p.items) == ["Mine", "[Chrome Bookmarks: A]"])
        if case .folder(let f) = p.items[1] { #expect(!f.expanded) }
        p.add(imp, inFolder: nil)
        #expect(names(p.items) == ["Mine", "[Chrome Bookmarks: A]", "A"])
        p.add(ImportedSidebar(name: "Empty"), inFolder: "Nothing")
        #expect(p.items.count == 3, "an empty import adds no folder")
    }

    @Test func arcSpacesBecomeSidebarProfilesAndReplaceAnUntouchedStarter() {
        let chrome = ProfileRef(browser: "com.google.Chrome", directory: "Default")
        var lib = SidebarLibrary.starter
        lib.link(chrome, to: lib.profiles[0].id)
        #expect(lib.isUntouched)
        let personal = ImportedSidebar(name: "Personal", favorites: [SavedLink(title: "Mail", url: "https://mail.example/")])
        let work = ImportedSidebar(name: "Work", items: [.link(SavedLink(title: "Docs", url: "https://docs.example/"))])
        let made = lib.addProfiles([personal, ImportedSidebar(name: "Empty"), work])
        #expect(lib.profiles.map(\.name) == ["Personal", "Work"])
        #expect(made == lib.profiles.map(\.id))
        #expect(lib.profile(for: chrome)?.name == "Personal", "the first import shows where the starter did")
        #expect(!lib.isUntouched)

        // A library someone has built keeps everything; a taken name gets a number.
        let again = lib.addProfiles([work])
        #expect(lib.profiles.map(\.name) == ["Personal", "Work", "Work 2"])
        #expect(again.count == 1)
        #expect(lib.addProfiles([ImportedSidebar(name: "Empty")]).isEmpty)
        #expect(lib.profiles.count == 3)
    }
}
