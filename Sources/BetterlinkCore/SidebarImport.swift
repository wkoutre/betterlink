import Foundation

/// Favorites and folders read from another browser, ready to become a Sidebar
/// Profile or a folder in one.
public struct ImportedSidebar: Equatable, Sendable {
    /// The Arc Space's name, or the kind of bookmarks ("Bookmarks").
    public var name: String
    public var favorites: [SavedLink]
    public var items: [SidebarItem]

    public init(name: String, favorites: [SavedLink] = [], items: [SidebarItem] = []) {
        self.name = name; self.favorites = favorites; self.items = items
    }

    /// Every link it brings, Favorites included.
    public var linkCount: Int { favorites.count + SidebarProfile.links(in: items).count }
    public var isEmpty: Bool { linkCount == 0 }
}

public enum SidebarImportError: Error, Equatable, CustomStringConvertible {
    case notArc
    case notBookmarks

    public var description: String {
        switch self {
        case .notArc: "This isn't Arc's sidebar file (StorableSidebar.json), or Arc changed its format."
        case .notBookmarks: "This isn't a browser's Bookmarks file."
        }
    }
}

/// Reads what people already built elsewhere: Arc's sidebar (Favorites and
/// pinned tabs with their folders, one import per Space), a Chromium
/// browser's bookmarks, and a bookmarks.html export from any browser.
/// Everything is read from a file the person has on their Mac; nothing is
/// fetched. Only web addresses are kept.
public enum SidebarImport {
    /// The most links one import brings in: more than anyone pins, and it
    /// keeps a huge or hostile file from swelling sidebar.json.
    public static let limit = 5000

    // MARK: - Arc

    /// Arc's `~/Library/Application Support/Arc/StorableSidebar.json`: one
    /// import per Space, with the Space's pinned tabs and folders, and the
    /// Favorites of the Space's profile.
    ///
    /// Arc doesn't document the file. It is Swift's own encoding: dictionaries
    /// are flat `key, value, key, value` arrays and enum cases are one-key
    /// objects, so everything here is found by label, never by position.
    public static func arc(_ data: Data) throws -> [ImportedSidebar] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let containers = (root["sidebar"] as? [String: Any])?["containers"] as? [Any],
              let main = mainContainer(containers) else { throw SidebarImportError.notArc }

        var items: [String: [String: Any]] = [:]
        for case let item as [String: Any] in main["items"] as? [Any] ?? [] {
            if let id = item["id"] as? String { items[id] = item }
        }
        var budget = limit

        // Favorites belong to a browser profile, which several Spaces can share.
        var favoritesByProfile: [(profile: String, links: [SavedLink])] = []
        for (label, id) in pairs(main["topAppsContainerIDs"] as? [Any] ?? []) {
            guard let id = id as? String else { continue }
            let links = SidebarProfile.links(in: arcChildren(of: id, items, &budget, seen: []))
            favoritesByProfile.append((profileKey(label), links))
        }

        var out: [ImportedSidebar] = []
        var n = 0
        for case let space as [String: Any] in main["spaces"] as? [Any] ?? [] {
            n += 1
            let title = (space["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Space \(n)"
            let pinned = pinnedContainer(space)
            let tree = pinned.map { arcChildren(of: $0, items, &budget, seen: []) } ?? []
            let key = profileKey(space["profile"])
            let favs = favoritesByProfile.first { $0.profile == key }?.links ?? []
            // Fresh ids: the same Favorites can land in several Sidebar Profiles.
            out.append(ImportedSidebar(name: title, favorites: favs.map { SavedLink(title: $0.title, url: $0.url) }, items: tree))
        }
        guard !out.isEmpty else { throw SidebarImportError.notArc }
        return out
    }

    /// The data object after the `{"global": {}}` marker. Little Arc and
    /// standalone windows have their own pairs, in any order.
    private static func mainContainer(_ containers: [Any]) -> [String: Any]? {
        for (i, c) in containers.enumerated() {
            guard let marker = c as? [String: Any], marker["global"] != nil, i + 1 < containers.count else { continue }
            if let next = containers[i + 1] as? [String: Any], next["items"] != nil { return next }
        }
        // An older or newer file with no marker: the one object holding both.
        return containers.compactMap { $0 as? [String: Any] }.first { $0["items"] != nil && $0["spaces"] != nil }
    }

    /// `[label, value, label, value]` as pairs.
    private static func pairs(_ flat: [Any]) -> [(Any, Any)] {
        stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }
    }

    /// A Space's pinned container: the id after the "pinned" label, in the
    /// plain list or the enum-labelled one (Arc writes them in either order).
    private static func pinnedContainer(_ space: [String: Any]) -> String? {
        for (label, id) in pairs(space["containerIDs"] as? [Any] ?? []) + pairs(space["newContainerIDs"] as? [Any] ?? []) {
            let isPinned = (label as? String) == "pinned" || (label as? [String: Any])?["pinned"] != nil
            if isPinned, let id = id as? String { return id }
        }
        return nil
    }

    /// "Default", or a custom profile's folder: what ties a Space to its Favorites.
    private static func profileKey(_ value: Any?) -> String {
        guard let d = value as? [String: Any] else { return "Default" }
        if let custom = (d["custom"] as? [String: Any])?["_0"] as? [String: Any],
           let dir = custom["directoryBasename"] as? String { return dir }
        return "Default"
    }

    private static func arcChildren(of id: String, _ items: [String: [String: Any]], _ budget: inout Int,
                                    seen: Set<String>) -> [SidebarItem] {
        guard let parent = items[id], !seen.contains(id) else { return [] }
        let seen = seen.union([id])
        var out: [SidebarItem] = []
        for case let child as String in parent["childrenIds"] as? [Any] ?? [] {
            // A file that lists a folder inside itself must not loop.
            guard !seen.contains(child), let item = items[child], let data = item["data"] as? [String: Any] else { continue }
            let title = (item["title"] as? String) ?? ""
            if let tab = data["tab"] as? [String: Any] {
                guard budget > 0, let url = tab["savedURL"] as? String, isWeb(url) else { continue }
                let name = !title.isEmpty ? title : ((tab["savedTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url)
                out.append(.link(SavedLink(title: name, url: url)))
                budget -= 1
            } else if data["list"] != nil {
                let inner = arcChildren(of: child, items, &budget, seen: seen)
                out.append(.folder(SidebarFolder(name: title.isEmpty ? "Folder" : title, expanded: false, items: inner)))
            } else if data["splitView"] != nil {
                // A split view is its tabs, side by side: keep the tabs.
                out += arcChildren(of: child, items, &budget, seen: seen)
            }
            // Easels and notes have no address to save.
        }
        return out
    }

    // MARK: - Chromium bookmarks

    /// A Chromium profile's `Bookmarks` file (Chrome, Brave, Edge, Dia, Arc):
    /// the bookmarks bar at the top level, then "Other Bookmarks" and
    /// "Mobile Bookmarks" as folders when they hold anything.
    public static func chromiumBookmarks(_ data: Data) throws -> ImportedSidebar {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else { throw SidebarImportError.notBookmarks }
        var budget = limit
        var items = chromiumChildren(roots["bookmark_bar"], &budget, depth: 0)
        for (key, name) in [("other", "Other Bookmarks"), ("synced", "Mobile Bookmarks")] {
            let inner = chromiumChildren(roots[key], &budget, depth: 0)
            if !inner.isEmpty { items.append(.folder(SidebarFolder(name: name, expanded: false, items: inner))) }
        }
        return ImportedSidebar(name: "Bookmarks", items: items)
    }

    private static func chromiumChildren(_ node: Any?, _ budget: inout Int, depth: Int) -> [SidebarItem] {
        guard depth < 32, let children = (node as? [String: Any])?["children"] as? [Any] else { return [] }
        var out: [SidebarItem] = []
        for case let c as [String: Any] in children {
            let name = (c["name"] as? String) ?? ""
            if c["type"] as? String == "folder" {
                let inner = chromiumChildren(c, &budget, depth: depth + 1)
                out.append(.folder(SidebarFolder(name: name.isEmpty ? "Folder" : name, expanded: false, items: inner)))
            } else if let url = c["url"] as? String, isWeb(url), budget > 0 {
                out.append(.link(SavedLink(title: name.isEmpty ? url : name, url: url)))
                budget -= 1
            }
        }
        return out
    }

    // MARK: - bookmarks.html

    /// A bookmarks.html export (the "Netscape bookmark file" every browser
    /// writes): folders are `<H3>` followed by a `<DL>` list, links are `<A HREF>`.
    /// An inline `ICON="data:…"` becomes the link's icon.
    public static func bookmarksHTML(_ text: String) -> ImportedSidebar {
        // One pass over the four tags that matter, in document order.
        let pattern = #"<H3[^>]*>(.*?)</H3>|<A\s([^>]*)>(.*?)</A>|<DL[^>]*>|</DL>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return ImportedSidebar(name: "Bookmarks")
        }
        let ns = text as NSString
        var budget = limit
        // The open lists, innermost last. A folder's name waits for its <DL>.
        var stack: [(name: String?, items: [SidebarItem])] = [(nil, [])]
        var pendingFolder: String?
        func close() {
            guard stack.count > 1 else { return }
            let done = stack.removeLast()
            if let name = done.name {
                stack[stack.count - 1].items.append(.folder(SidebarFolder(name: name, expanded: false, items: done.items)))
            } else {
                stack[stack.count - 1].items += done.items
            }
        }
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let whole = ns.substring(with: m.range).uppercased()
            if m.range(at: 1).location != NSNotFound {
                let name = unescape(stripTags(ns.substring(with: m.range(at: 1))))
                pendingFolder = name.isEmpty ? "Folder" : name
            } else if m.range(at: 2).location != NSNotFound {
                let attrs = ns.substring(with: m.range(at: 2))
                guard budget > 0, let url = attribute("HREF", in: attrs).map(unescape), isWeb(url) else { continue }
                let title = unescape(stripTags(ns.substring(with: m.range(at: 3))))
                let icon = attribute("ICON", in: attrs).flatMap { $0.hasPrefix("data:image/") && $0.count < 64 * 1024 ? $0 : nil }
                stack[stack.count - 1].items.append(.link(SavedLink(title: title.isEmpty ? url : title, url: url, icon: icon)))
                budget -= 1
            } else if whole.hasPrefix("<DL") {
                guard stack.count < 32 else { continue }
                stack.append((pendingFolder, []))
                pendingFolder = nil
            } else {
                close()
            }
        }
        while stack.count > 1 { close() }
        return ImportedSidebar(name: "Bookmarks", items: stack[0].items)
    }

    private static func attribute(_ name: String, in attrs: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "(?:^|\\s)\(name)\\s*=\\s*\"([^\"]*)\"", options: .caseInsensitive) else { return nil }
        let ns = attrs as NSString
        guard let m = re.firstMatch(in: attrs, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The few character references bookmark files use.
    static func unescape(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (a, b) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: a, with: b)
        }
        if let re = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});") {
            let ns = out as NSString
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed() {
                let code = ns.substring(with: m.range(at: 1))
                let value = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let value, let scalar = Unicode.Scalar(value) {
                    out = (out as NSString).replacingCharacters(in: m.range, with: String(Character(scalar)))
                }
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }

    /// Only pages on the web: no chrome://, javascript:, file: or arc:// entries.
    static func isWeb(_ url: String) -> Bool {
        let u = url.lowercased()
        return u.hasPrefix("https://") || u.hasPrefix("http://")
    }
}

extension SidebarProfile {
    /// Brings an import into this Sidebar Profile. Its Favorites join the
    /// Favorites (an address already there is skipped). Its folders and links
    /// go into a new closed folder named `folder`, or straight to the end of
    /// the top level when `folder` is nil.
    public mutating func add(_ imported: ImportedSidebar, inFolder folder: String?) {
        for f in imported.favorites { addFavorite(f) }
        guard !imported.items.isEmpty else { return }
        if let folder {
            items.append(.folder(SidebarFolder(name: folder, expanded: false, items: imported.items)))
        } else {
            items += imported.items
        }
    }
}

extension SidebarLibrary {
    /// True while the library is still the untouched starter: one profile with
    /// nothing saved.
    public var isUntouched: Bool {
        profiles.count == 1 && profiles[0].favorites.isEmpty && profiles[0].items.isEmpty
    }

    /// Makes each import a Sidebar Profile of its own (an Arc Space becomes a
    /// Sidebar Profile). Empty ones are skipped; a name already in use gets a
    /// number. An untouched starter library is replaced instead of kept as an
    /// empty first profile, keeping its browser-profile links. Returns the new
    /// profiles' ids.
    @discardableResult
    public mutating func addProfiles(_ imported: [ImportedSidebar]) -> [UUID] {
        let fresh = imported.filter { !$0.isEmpty }
        guard !fresh.isEmpty else { return [] }
        let starter = isUntouched ? profiles.first : nil
        if starter != nil { profiles = [] }
        var made: [UUID] = []
        for (i, imp) in fresh.enumerated() {
            var name = imp.name, n = 2
            while profiles.contains(where: { $0.name == name }) { name = "\(imp.name) \(n)"; n += 1 }
            var p = SidebarProfile(name: name, favorites: [], items: imp.items)
            for f in imp.favorites { p.addFavorite(f) }
            // The first takes the starter's place for the browser profiles it showed for.
            if i == 0, let starter { p.browserProfiles = starter.browserProfiles }
            profiles.append(p)
            made.append(p.id)
        }
        return made
    }
}
