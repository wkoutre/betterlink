import Foundation

// The sidebar's saved things as agent commands: Sidebar Profiles, Favorites,
// folders and saved links, which browser profile shows which Sidebar
// Profile, and imports. Everything the sidebar's menus and drags change in
// sidebar.json, through SidebarStore's lock, so the app (which watches the
// file) and an agent never lose each other's changes.
//
// A Sidebar Profile is named by its id or its name (`profile`); left out, it
// is the only one there is. A favorite, folder or saved link is named by its
// id, or by the start of its id when that start is unique (`id`). Positions
// count from 1.
extension Agent {
    static let sidebarCommands: [String] = [
        "sidebar.list",
        "sidebar.profiles.add", "sidebar.profiles.rename", "sidebar.profiles.remove",
        "sidebar.profiles.assign", "sidebar.profiles.unassign",
        "sidebar.folders.add", "sidebar.links.add",
        "sidebar.items.update", "sidebar.items.move", "sidebar.items.remove", "sidebar.items.expand",
        "sidebar.import",
    ]

    static func sidebarRun(_ command: String, _ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse? {
        switch command {
        case "sidebar.list":
            // With no sidebar.json yet, save the starter first: unsaved, it
            // gets a new id in every process, so a listed id wouldn't work
            // in the next command.
            let store = SidebarStore(folder: env.folder)
            // A file with no profiles loads as the starter too, unsaved.
            let saved = FileManager.default.contents(atPath: store.file.path).flatMap { try? JSONDecoder().decode(SidebarLibrary.self, from: $0) }
            let lib = (saved?.profiles.isEmpty ?? true) ? try store.update { _ in } : try store.load()
            return .success(lib.profiles.map(describeProfile))
        case "sidebar.profiles.add": return try profilesAddSidebar(input, env)
        case "sidebar.profiles.rename": return try edit(input, env) { lib, p in
            guard let name = try nonEmpty(input, "name") else { throw fail("Give name: the new name.") }
            lib.update(p) { $0.name = name }
        }
        case "sidebar.profiles.remove": return try profilesRemoveSidebar(input, env)
        case "sidebar.profiles.assign": return try assign(input, env)
        case "sidebar.profiles.unassign": return try unassign(input, env)
        case "sidebar.folders.add": return try foldersAdd(input, env)
        case "sidebar.links.add": return try linksAdd(input, env)
        case "sidebar.items.update": return try itemsUpdate(input, env)
        case "sidebar.items.move": return try itemsMove(input, env)
        case "sidebar.items.remove": return try itemsRemove(input, env)
        case "sidebar.items.expand": return try itemsExpand(input, env)
        case "sidebar.import": return try importSidebar(input, env)
        default: return nil
        }
    }

    // MARK: Tabs a close spares

    /// The tabs Close Other Tabs and Close Tabs Below leave open: any tab at a
    /// saved link's address in any Sidebar Profile (the sidebar's menu spares
    /// the tabs its saved links claim, LinkResolution), and any tab at an
    /// address the app remembers a saved link holding (HoldLedger.remembered:
    /// profile key -> link id -> addresses). Sparing too much is safe;
    /// closing a held tab is not.
    public static func sparedTabs(_ tabs: [(id: Int, url: String)], library: SidebarLibrary,
                                  remembered: [String: [String: [String]]]) -> Set<Int> {
        var keys = Set(library.profiles.flatMap { $0.allLinks.map { SavedLink.key($0.url) } })
        for byLink in remembered.values { for addresses in byLink.values { for a in addresses { keys.insert(SavedLink.key(a)) } } }
        return Set(tabs.filter { !$0.url.isEmpty && keys.contains(SavedLink.key($0.url)) }.map(\.id))
    }

    // MARK: Reading

    static func describeProfile(_ p: SidebarProfile) -> [String: Any] {
        [
            "id": p.id.uuidString,
            "name": p.name,
            "browserProfiles": p.browserProfiles.map { ["browser": $0.browser, "profile": $0.directory] },
            "favorites": p.favorites.map(describeLink),
            "items": p.items.map(describeItem),
        ]
    }

    static func describeLink(_ l: SavedLink) -> [String: Any] {
        ["id": l.id.uuidString, "kind": "link", "title": l.title, "url": l.url]
    }

    static func describeItem(_ item: SidebarItem) -> [String: Any] {
        switch item {
        case .link(let l): return describeLink(l)
        case .folder(let f):
            return ["id": f.id.uuidString, "kind": "folder", "name": f.name, "expanded": f.expanded, "items": f.items.map(describeItem)]
        }
    }

    // MARK: Finding things

    static func nonEmpty(_ input: [String: Any], _ key: String) throws -> String? {
        guard let s = try string(input, key) else { return nil }
        guard !s.isEmpty else { throw fail("\(key) can't be empty.") }
        return s
    }

    /// The Sidebar Profile `input.profile` names: an id, a name (any case), or
    /// nothing when there is only one.
    static func sidebarProfile(_ input: [String: Any], _ lib: SidebarLibrary) throws -> SidebarProfile {
        let names = lib.profiles.map { "\"\($0.name)\"" }.joined(separator: ", ")
        guard let key = try nonEmpty(input, "profile") else {
            if lib.profiles.count == 1 { return lib.profiles[0] }
            throw fail("Give profile: which Sidebar Profile (\(names)).")
        }
        if let u = UUID(uuidString: key), let p = lib.profiles.first(where: { $0.id == u }) { return p }
        let byName = lib.profiles.filter { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == key.lowercased() }
        if byName.count == 1 { return byName[0] }
        if byName.count > 1 { throw fail("More than one Sidebar Profile is called \"\(key)\": give its id (sidebar list).") }
        throw fail("No Sidebar Profile \"\(key)\". There are: \(names).")
    }

    /// Every id in a Sidebar Profile: its Favorites, folders and saved links.
    static func allIDs(_ p: SidebarProfile) -> [UUID] {
        func walk(_ items: [SidebarItem]) -> [UUID] {
            items.flatMap { item -> [UUID] in
                if case .folder(let f) = item { return [f.id] + walk(f.items) }
                return [item.id]
            }
        }
        return p.favorites.map(\.id) + walk(p.items)
    }

    /// The favorite, folder or saved link `input[key]` names: its id, or a
    /// start of its id at least 4 characters long that only it has.
    static func itemID(_ input: [String: Any], _ key: String, in p: SidebarProfile) throws -> UUID? {
        guard let s = try nonEmpty(input, key) else { return nil }
        let ids = allIDs(p)
        if let u = UUID(uuidString: s) {
            guard ids.contains(u) else { throw fail("\(key): nothing with id \(s) in \"\(p.name)\".") }
            return u
        }
        guard s.count >= 4 else { throw fail("\(key): give an id, or at least its first 4 characters.") }
        let hits = ids.filter { $0.uuidString.lowercased().hasPrefix(s.lowercased()) }
        if hits.count == 1 { return hits[0] }
        throw fail(hits.isEmpty ? "\(key): nothing in \"\(p.name)\" has an id starting \(s)." : "\(key): more than one id starts \(s); give more of it.")
    }

    static func isFolder(_ id: UUID, in p: SidebarProfile) -> Bool {
        if case .folder = SidebarProfile.find(id, in: p.items) { return true }
        return false
    }

    /// Where `input` says to put something: `to` is "favorites", "top" or a
    /// folder's id; `position` counts from 1 (left out: the end).
    static func spot(_ input: [String: Any], in p: SidebarProfile, default fallback: String = "top") throws -> SidebarProfile.Spot {
        let to = try nonEmpty(input, "to") ?? fallback
        let index = try position(input, "position").map { $0 - 1 } ?? .max
        switch to.lowercased() {
        case "favorites": return .favorites(index)
        case "top": return .items(parent: nil, index: index)
        default:
            guard let folder = try itemID(["to": to], "to", in: p), isFolder(folder, in: p) else {
                throw fail("to must be \"favorites\", \"top\" or a folder's id.")
            }
            return .items(parent: folder, index: index)
        }
    }

    /// Loads the library, applies `change` to the named Sidebar Profile and
    /// answers with that profile as it is after.
    static func edit(_ input: [String: Any], _ env: AgentEnvironment,
                     _ change: (inout SidebarLibrary, UUID) throws -> Void) throws -> AgentResponse {
        var id: UUID?
        let lib = try SidebarStore(folder: env.folder).update { lib in
            let p = try sidebarProfile(input, lib)
            id = p.id
            try change(&lib, p.id)
        }
        guard let p = lib.profiles.first(where: { $0.id == id }) else { return .success(nil) }
        return .success(describeProfile(p))
    }

    // MARK: Sidebar Profiles

    static func profilesAddSidebar(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard let name = try nonEmpty(input, "name") else { throw fail("Give name: the new Sidebar Profile's name.") }
        var made: SidebarProfile?
        _ = try SidebarStore(folder: env.folder).update { lib in
            let p = SidebarProfile(name: name)
            lib.profiles.append(p)
            made = p
        }
        return .success(made.map(describeProfile))
    }

    static func profilesRemoveSidebar(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard try nonEmpty(input, "profile") != nil else { throw fail("Give profile: which Sidebar Profile to delete.") }
        var removed = ""
        _ = try SidebarStore(folder: env.folder).update { lib in
            let p = try sidebarProfile(input, lib)
            guard lib.profiles.count > 1 else { throw fail("\"\(p.name)\" is the only Sidebar Profile; there must be one.") }
            removed = p.name
            lib.removeProfile(p.id)
        }
        return .success(["removed": removed])
    }

    /// The browser profile `input` names (`browser`: a name or bundle id;
    /// `browserProfile`: its folder, such as "Default" or "Profile 1").
    static func browserProfile(_ input: [String: Any], _ env: AgentEnvironment) throws -> ProfileRef {
        guard let b = try nonEmpty(input, "browser") else { throw fail("Give browser: its name or bundle id (browsers list).") }
        guard let dir = try nonEmpty(input, "browserProfile") else {
            throw fail("Give browserProfile: the browser profile's folder, such as \"Default\" or \"Profile 1\" (profiles list).")
        }
        let known = Browser.known.first { $0.bundleId.lowercased() == b.lowercased() || $0.name.lowercased() == b.lowercased() }
        guard let browser = known else { throw fail("No browser \"\(b)\" betterlink knows (browsers list).") }
        return ProfileRef(browser: browser.bundleId, directory: dir)
    }

    static func assign(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        let ref = try browserProfile(input, env)
        return try edit(input, env) { lib, p in lib.link(ref, to: p) }
    }

    static func unassign(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        let ref = try browserProfile(input, env)
        _ = try SidebarStore(folder: env.folder).update { lib in
            for i in lib.profiles.indices { lib.profiles[i].browserProfiles.removeAll { $0 == ref } }
        }
        return .success(["browser": ref.browser, "browserProfile": ref.directory,
                         "note": "This browser profile now shows the default Sidebar Profile (the first one linked to nothing)."])
    }

    // MARK: Favorites, folders and saved links

    static func foldersAdd(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard let name = try nonEmpty(input, "name") else { throw fail("Give name: the folder's name.") }
        var made: UUID?
        let r = try edit(input, env) { lib, pid in
            let p = lib.profiles.first { $0.id == pid }!
            let target = try spot(input, in: p)
            guard case .items(let parent, let index) = target else { throw fail("A folder can't go in Favorites.") }
            lib.update(pid) { p in
                let id = p.addFolder(name, in: parent)
                if index != .max { p.place(id, at: .items(parent: parent, index: index)) }
                made = id
            }
        }
        return made.map { _ in .success(["id": made!.uuidString, "profile": r.data as Any]) } ?? r
    }

    static func linksAdd(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard let url = try nonEmpty(input, "url") else { throw fail("Give url: the page to save.") }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme), parsed.host != nil else {
            throw fail("url must be a full http or https address, such as https://example.com.")
        }
        let title = try nonEmpty(input, "title") ?? parsed.host!
        let link = SavedLink(title: title, url: url)
        let r = try edit(input, env) { lib, pid in
            let p = lib.profiles.first { $0.id == pid }!
            let target = try spot(input, in: p)
            if case .favorites = target, p.favorites.contains(where: { SavedLink.same($0.url, url) }) {
                throw fail("A favorite in \"\(p.name)\" already has this address.")
            }
            lib.update(pid) { $0.insert(link, at: target) }
        }
        return .success(["id": link.id.uuidString, "profile": r.data as Any])
    }

    static func itemsUpdate(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try edit(input, env) { lib, pid in
            let p = lib.profiles.first { $0.id == pid }!
            guard let id = try itemID(input, "id", in: p) else { throw fail("Give id: the favorite, folder or saved link to change.") }
            let name = try nonEmpty(input, "name") ?? nonEmpty(input, "title")
            let url = try nonEmpty(input, "url")
            guard name != nil || url != nil else { throw fail("Give name (or title) and/or url.") }
            if let url {
                guard p.savedLink(id) != nil else { throw fail("Only a favorite or saved link has a url; this is a folder.") }
                guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else {
                    throw fail("url must be a full http or https address.")
                }
                lib.update(pid) { $0.repoint(id, to: url, title: name) }
            } else if let name {
                lib.update(pid) { $0.rename(id, to: name) }
            }
        }
    }

    static func itemsMove(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try edit(input, env) { lib, pid in
            let p = lib.profiles.first { $0.id == pid }!
            guard let id = try itemID(input, "id", in: p) else { throw fail("Give id: what to move.") }
            guard try nonEmpty(input, "to") != nil || input["position"] != nil else {
                throw fail("Give to (\"favorites\", \"top\" or a folder's id) and/or position.")
            }
            // Left out, `to` is where the item is now: a reorder.
            let here: String = p.favorites.contains(where: { $0.id == id }) ? "favorites" : (p.parent(of: id)?.uuidString ?? "top")
            let target = try spot(input, in: p, default: here)
            guard p.canPlace(id, at: target) else {
                if case .favorites = target, isFolder(id, in: p) { throw fail("A folder can't go in Favorites.") }
                if case .favorites = target { throw fail("A favorite already has this address.") }
                throw fail("That move isn't possible: a folder can't go inside itself.")
            }
            lib.update(pid) { $0.place(id, at: target) }
        }
    }

    static func itemsRemove(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try edit(input, env) { lib, pid in
            let p = lib.profiles.first { $0.id == pid }!
            guard let id = try itemID(input, "id", in: p) else { throw fail("Give id: what to delete.") }
            if case .folder(let f) = SidebarProfile.find(id, in: p.items), !f.items.isEmpty, try bool(input, "withContents") != true {
                throw fail("Folder \"\(f.name)\" isn't empty (\(SidebarProfile.links(in: f.items).count) saved links). Give withContents: true to delete it and everything in it.")
            }
            lib.update(pid) { $0.remove(id) }
        }
    }

    static func itemsExpand(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try edit(input, env) { lib, pid in
            let p = lib.profiles.first { $0.id == pid }!
            guard let id = try itemID(input, "id", in: p), case .folder(let f) = SidebarProfile.find(id, in: p.items) else {
                throw fail("Give id: a folder's id.")
            }
            guard let open = try bool(input, "expanded") else { throw fail("Give expanded: true or false.") }
            if f.expanded != open { lib.update(pid) { $0.toggleExpanded(id) } }
        }
    }

    // MARK: Import

    /// `from`: "browser" (with `browser` and `browserProfile`: that profile's
    /// bookmarks), "file" (with `path`: a bookmarks.html export, a Chromium
    /// Bookmarks file or Arc's StorableSidebar.json) or "arc" (Arc's sidebar on
    /// this Mac). Bookmarks go into one closed folder in `profile`; each Arc
    /// Space becomes a Sidebar Profile of its own.
    static func importSidebar(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        func read(_ url: URL) throws -> Data {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= 64 << 20 else { throw fail("\(url.lastPathComponent) is too big to be bookmarks.") }
            guard let d = FileManager.default.contents(atPath: url.path) else { throw fail("Can't read \(url.path).") }
            return d
        }
        func arc(_ url: URL) throws -> AgentResponse {
            let spaces = try SidebarImport.arc(try read(url))
            var made: [UUID] = []
            let lib = try SidebarStore(folder: env.folder).update { made = $0.addProfiles(spaces) }
            return .success(["imported": lib.profiles.filter { made.contains($0.id) }.map(describeProfile)])
        }
        func bookmarks(_ url: URL, named name: String) throws -> AgentResponse {
            let data = try read(url)
            let imported: ImportedSidebar
            if let c = try? SidebarImport.chromiumBookmarks(data) { imported = c }
            else if let text = String(data: data, encoding: .utf8), text.lowercased().contains("<dl") { imported = SidebarImport.bookmarksHTML(text) }
            else { throw fail("\(url.lastPathComponent) isn't a bookmarks file this can read.") }
            guard !imported.isEmpty else { throw fail("No bookmarks in \(url.lastPathComponent).") }
            let r = try edit(input, env) { lib, pid in lib.update(pid) { $0.add(imported, inFolder: name) } }
            return .success(["links": imported.linkCount, "folder": name, "profile": r.data as Any])
        }
        switch try nonEmpty(input, "from")?.lowercased() {
        case "arc":
            let file = home.appendingPathComponent("Arc/StorableSidebar.json")
            guard FileManager.default.fileExists(atPath: file.path) else { throw fail("Arc's sidebar file isn't on this Mac.") }
            return try arc(file)
        case "file":
            guard let path = try nonEmpty(input, "path") else { throw fail("Give path: the file to import.") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            return url.lastPathComponent.hasPrefix("StorableSidebar") ? try arc(url) : try bookmarks(url, named: "Bookmarks")
        case "browser":
            let ref = try browserProfile(input, env)
            guard let b = Browser.known(bundleId: ref.browser), b.family == .chromium, let folder = b.dataFolder else {
                throw fail("Only Chromium browsers' bookmarks can be imported this way; export bookmarks.html and use from: \"file\".")
            }
            let file = home.appendingPathComponent(folder).appendingPathComponent(ref.directory).appendingPathComponent("Bookmarks")
            guard FileManager.default.fileExists(atPath: file.path) else { throw fail("\(b.name) profile \(ref.directory) has no bookmarks.") }
            return try bookmarks(file, named: "\(b.name) Bookmarks")
        default:
            throw fail("Give from: \"browser\" (with browser and browserProfile), \"file\" (with path) or \"arc\".")
        }
    }
}
