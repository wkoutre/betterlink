import Foundation

/// What the betterlink sidebar keeps, like Arc's and Dia's sidebars: for each
/// Sidebar Profile a grid of Favorites and a tree of folders of saved links.
/// Each Sidebar Profile is shown for the browser profiles it is linked to.
/// Saved in the settings folder as sidebar.json, so it syncs with the rules.
public struct SidebarLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public var profiles: [SidebarProfile]

    public init(profiles: [SidebarProfile] = []) { self.profiles = profiles }

    /// The Sidebar Profile for a browser profile: the one linked to it, else
    /// the first one linked to nothing (the catch-all), else the first.
    public func profile(for ref: ProfileRef?) -> SidebarProfile? {
        if let ref, let linked = profiles.first(where: { $0.browserProfiles.contains(ref) }) { return linked }
        return profiles.first { $0.browserProfiles.isEmpty } ?? profiles.first
    }

    /// The library with one profile, "Primary", for everything.
    public static let starter = SidebarLibrary(profiles: [SidebarProfile(name: "Primary")])

    /// Shows `id` for `ref` from now on (and no other profile for it).
    public mutating func link(_ ref: ProfileRef, to id: UUID) {
        for i in profiles.indices {
            profiles[i].browserProfiles.removeAll { $0 == ref }
            if profiles[i].id == id { profiles[i].browserProfiles.append(ref) }
        }
    }

    /// Removes a Sidebar Profile; the last one is kept.
    public mutating func removeProfile(_ id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
    }

    public mutating func update(_ id: UUID, _ change: (inout SidebarProfile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        change(&profiles[i])
    }

    /// The id of every saved link in every Sidebar Profile.
    public var allLinkIDs: Set<UUID> {
        Set(profiles.flatMap { $0.allLinks.map(\.id) })
    }
}

public struct SidebarProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// The browser profiles that show this Sidebar Profile. Empty: every
    /// browser profile not linked to another one.
    public var browserProfiles: [ProfileRef]
    /// The grid of icons at the top.
    public var favorites: [SavedLink]
    /// Folders and links, in order.
    public var items: [SidebarItem]

    public init(id: UUID = UUID(), name: String, browserProfiles: [ProfileRef] = [],
                favorites: [SavedLink] = [], items: [SidebarItem] = []) {
        self.id = id; self.name = name; self.browserProfiles = browserProfiles
        self.favorites = favorites; self.items = items
    }

    // MARK: - Editing

    /// Adds a folder at the end of `parent` (nil: the top level).
    @discardableResult
    public mutating func addFolder(_ name: String, in parent: UUID? = nil) -> UUID {
        let f = SidebarFolder(name: name)
        insert(.folder(f), into: parent)
        return f.id
    }

    /// Saves a link at the end of `parent` (nil: the top level).
    public mutating func addLink(_ link: SavedLink, in parent: UUID? = nil) {
        insert(.link(link), into: parent)
    }

    public mutating func addFavorite(_ link: SavedLink) {
        guard !favorites.contains(where: { SavedLink.same($0.url, link.url) }) else { return }
        favorites.append(link)
    }

    /// Removes a folder (with everything in it), a link or a favorite.
    public mutating func remove(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        items = Self.removing(id, from: items)
    }

    public mutating func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        if let i = favorites.firstIndex(where: { $0.id == id }) { favorites[i].title = n }
        items = Self.mapping(items) { item in
            switch item {
            case .folder(var f) where f.id == id: f.name = n; return .folder(f)
            case .link(var l) where l.id == id: l.title = n; return .link(l)
            default: return item
            }
        }
    }

    /// A saved link (a Favorite or one in a folder) by id.
    public func savedLink(_ id: UUID) -> SavedLink? {
        allLinks.first { $0.id == id }
    }

    /// Points a saved link at another page: "save the page this tab is on
    /// here". The name follows when one is given; the icon is replaced, since
    /// the old one belongs to the old page.
    public mutating func repoint(_ id: UUID, to url: String, title: String? = nil, icon: String? = nil) {
        guard !url.isEmpty else { return }
        func moved(_ l: SavedLink) -> SavedLink {
            var l = l
            l.url = url
            if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { l.title = t }
            l.icon = icon
            return l
        }
        if let i = favorites.firstIndex(where: { $0.id == id }) { favorites[i] = moved(favorites[i]) }
        items = Self.mapping(items) { item in
            if case .link(let l) = item, l.id == id { return .link(moved(l)) }
            return item
        }
    }

    /// Gives saved links that have no icon the one their open tab shows (an
    /// imported link has none until its page has been open once). Links that
    /// already have an icon keep it. True when anything changed.
    @discardableResult
    public mutating func learnIcons(_ icons: [UUID: String]) -> Bool {
        guard !icons.isEmpty else { return false }
        var changed = false
        for i in favorites.indices where favorites[i].icon == nil {
            if let icon = icons[favorites[i].id] { favorites[i].icon = icon; changed = true }
        }
        items = Self.mapping(items) { item in
            if case .link(var l) = item, l.icon == nil, let icon = icons[l.id] { l.icon = icon; changed = true; return .link(l) }
            return item
        }
        return changed
    }

    /// The saved links with no icon yet whose tab has one to give, for `learnIcons`.
    public func iconsToLearn(from tabIcons: [UUID: String]) -> [UUID: String] {
        guard !tabIcons.isEmpty else { return [:] }
        var out: [UUID: String] = [:]
        for l in allLinks where l.icon == nil {
            if let icon = tabIcons[l.id], icon.hasPrefix("data:image/") { out[l.id] = icon }
        }
        return out
    }

    public mutating func toggleExpanded(_ id: UUID) {
        items = Self.mapping(items) { item in
            if case .folder(var f) = item, f.id == id { f.expanded.toggle(); return .folder(f) }
            return item
        }
    }

    /// Moves an item into `parent` (nil: the top level), at the end. A folder
    /// can't move into itself or into one of its own folders.
    public mutating func move(_ id: UUID, into parent: UUID?) {
        guard let item = Self.find(id, in: items), id != parent else { return }
        // Only into a folder that exists: anything else would drop the item (review F1).
        if let parent, !isFolder(parent) { return }
        if let parent, case .folder(let f) = item, Self.find(parent, in: f.items) != nil { return }
        items = Self.removing(id, from: items)
        insert(item, into: parent)
    }

    /// Where an item can go: a position in the Favorites grid, or a position
    /// among a folder's items (`parent` nil: the top level). Indexes count the
    /// list as it is before the move and are clamped to its ends.
    public enum Spot: Equatable, Sendable {
        case favorites(Int)
        case items(parent: UUID?, index: Int)
    }

    /// Moves a favorite, a saved link or a folder to `spot`: reorders it, moves it
    /// into or out of a folder, or between the Favorites grid and the folders (a
    /// link becomes a favorite and back). Does nothing when the move can't be
    /// made: a folder into the grid or into itself, a folder that doesn't exist,
    /// or a link to the grid when a favorite already has its address.
    public mutating func place(_ id: UUID, at spot: Spot) {
        let fromFavorites = favorites.firstIndex { $0.id == id }
        guard fromFavorites != nil || Self.find(id, in: items) != nil else { return }
        let item: SidebarItem = fromFavorites.map { .link(favorites[$0]) } ?? Self.find(id, in: items)!
        switch spot {
        case .favorites(let index):
            guard case .link(let l) = item else { return }
            if fromFavorites == nil, favorites.contains(where: { SavedLink.same($0.url, l.url) }) { return }
            var i = min(max(index, 0), favorites.count)
            if let from = fromFavorites {
                if from < i { i -= 1 }
                favorites.remove(at: from)
            } else {
                items = Self.removing(id, from: items)
            }
            favorites.insert(l, at: min(i, favorites.count))
        case .items(let parent, let index):
            if let parent {
                guard isFolder(parent), parent != id else { return }
                if case .folder(let f) = item, Self.find(parent, in: f.items) != nil { return }
            }
            // The index counts the target list before this item leaves it.
            var i = max(index, 0)
            if fromFavorites == nil, let from = children(of: parent).firstIndex(where: { $0.id == id }), from < i { i -= 1 }
            if let from = fromFavorites { favorites.remove(at: from) } else { items = Self.removing(id, from: items) }
            insert(item, into: parent, at: i)
        }
    }

    /// What `remove(_:)` took out and where it was, so Undo can put back just
    /// that, leaving everything changed since alone.
    public struct Removed: Equatable, Sendable {
        public var item: SidebarItem
        public var spot: Spot
    }

    /// Removes a favorite, saved link or folder (with everything in it) and
    /// says where it was.
    @discardableResult
    public mutating func take(_ id: UUID) -> Removed? {
        if let i = favorites.firstIndex(where: { $0.id == id }) {
            return Removed(item: .link(favorites.remove(at: i)), spot: .favorites(i))
        }
        guard let item = Self.find(id, in: items) else { return nil }
        let parent = parent(of: id)
        let index = children(of: parent).firstIndex { $0.id == id } ?? 0
        items = Self.removing(id, from: items)
        return Removed(item: item, spot: .items(parent: parent, index: index))
    }

    /// Puts back what `take(_:)` removed: where it was, or at the top level
    /// when its folder is gone meanwhile. Nothing when it is back already.
    public mutating func restore(_ r: Removed) {
        guard favorites.first(where: { $0.id == r.item.id }) == nil, Self.find(r.item.id, in: items) == nil else { return }
        switch (r.spot, r.item) {
        case (.favorites(let i), .link(let l)):
            if favorites.contains(where: { SavedLink.same($0.url, l.url) }) { insert(r.item, into: nil, at: .max) }
            else { favorites.insert(l, at: min(i, favorites.count)) }
        case (.items(let parent, let i), _):
            if let parent, !isFolder(parent) { insert(r.item, into: nil, at: .max) } // its folder is gone
            else { insert(r.item, into: parent, at: i) }
        default:
            insert(r.item, into: nil, at: .max)
        }
    }

    /// Whether `place(id, at: spot)` would change anything: drop targets
    /// refuse what it would refuse.
    public func canPlace(_ id: UUID, at spot: Spot) -> Bool {
        var copy = self
        copy.place(id, at: spot)
        return copy != self || isAt(id, spot)
    }

    /// True when `id` already sits exactly at `spot` (a drop on itself).
    private func isAt(_ id: UUID, _ spot: Spot) -> Bool {
        switch spot {
        case .favorites(let i): return favorites.indices.contains(i) && favorites[i].id == id || (i > 0 && favorites.indices.contains(i - 1) && favorites[i - 1].id == id)
        case .items(let parent, let i):
            let list = children(of: parent)
            return list.indices.contains(i) && list[i].id == id || (i > 0 && list.indices.contains(i - 1) && list[i - 1].id == id)
        }
    }

    /// Saves a new link (a tab dragged in) at `spot`.
    public mutating func insert(_ link: SavedLink, at spot: Spot) {
        switch spot {
        case .favorites(let index):
            guard !favorites.contains(where: { SavedLink.same($0.url, link.url) }) else { return }
            favorites.insert(link, at: min(max(index, 0), favorites.count))
        case .items(let parent, let index):
            insert(.link(link), into: parent, at: max(index, 0))
        }
    }

    /// The items directly in `parent` (nil: the top level), in order.
    public func children(of parent: UUID?) -> [SidebarItem] {
        guard let parent else { return items }
        if case .folder(let f) = Self.find(parent, in: items) { return f.items }
        return []
    }

    /// The folder directly holding `id` (nil: the top level, or not found).
    public func parent(of id: UUID) -> UUID? {
        func search(_ list: [SidebarItem], _ owner: UUID?) -> UUID?? {
            for item in list {
                if item.id == id { return .some(owner) }
                if case .folder(let f) = item, let hit = search(f.items, f.id) { return hit }
            }
            return nil
        }
        return search(items, nil) ?? nil
    }

    /// Every saved link, folders included, depth first.
    public var allLinks: [SavedLink] { favorites + Self.links(in: items) }

    private func isFolder(_ id: UUID) -> Bool {
        if case .folder = Self.find(id, in: items) { return true }
        return false
    }

    /// Into `parent` when it is a folder, else at the top level: a folder deleted
    /// meanwhile (by a sync, say) must not swallow what is being saved.
    private mutating func insert(_ item: SidebarItem, into parent: UUID?, at index: Int = .max) {
        guard let parent, isFolder(parent) else { items.insert(item, at: min(index, items.count)); return }
        items = Self.mapping(items) { node in
            if case .folder(var f) = node, f.id == parent {
                f.items.insert(item, at: min(index, f.items.count)); f.expanded = true; return .folder(f)
            }
            return node
        }
    }

    public static func links(in items: [SidebarItem]) -> [SavedLink] {
        items.flatMap { item -> [SavedLink] in
            switch item {
            case .link(let l): return [l]
            case .folder(let f): return links(in: f.items)
            }
        }
    }

    public static func find(_ id: UUID, in items: [SidebarItem]) -> SidebarItem? {
        for item in items {
            if item.id == id { return item }
            if case .folder(let f) = item, let hit = find(id, in: f.items) { return hit }
        }
        return nil
    }

    static func removing(_ id: UUID, from items: [SidebarItem]) -> [SidebarItem] {
        items.compactMap { item in
            if item.id == id { return nil }
            if case .folder(var f) = item { f.items = removing(id, from: f.items); return .folder(f) }
            return item
        }
    }

    /// Applies `change` to every item, depth first, children before parents.
    static func mapping(_ items: [SidebarItem], _ change: (SidebarItem) -> SidebarItem) -> [SidebarItem] {
        items.map { item in
            if case .folder(var f) = item { f.items = mapping(f.items, change); return change(.folder(f)) }
            return change(item)
        }
    }
}

public enum SidebarItem: Codable, Equatable, Identifiable, Sendable {
    case folder(SidebarFolder)
    case link(SavedLink)

    public var id: UUID {
        switch self {
        case .folder(let f): return f.id
        case .link(let l): return l.id
        }
    }

    public var isFolder: Bool {
        if case .folder = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey { case folder, link }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let f = try c.decodeIfPresent(SidebarFolder.self, forKey: .folder) { self = .folder(f); return }
        self = .link(try c.decode(SavedLink.self, forKey: .link))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder(let f): try c.encode(f, forKey: .folder)
        case .link(let l): try c.encode(l, forKey: .link)
        }
    }
}

public struct SidebarFolder: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var expanded: Bool
    public var items: [SidebarItem]

    public init(id: UUID = UUID(), name: String, expanded: Bool = true, items: [SidebarItem] = []) {
        self.id = id; self.name = name; self.expanded = expanded; self.items = items
    }
}

/// A saved link, like an Arc pinned tab: it shows as open while a tab with
/// its address is open, and clicking it switches to that tab or opens it.
public struct SavedLink: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var url: String
    /// The site's icon as a data: URL, captured when the link was saved.
    public var icon: String?

    public init(id: UUID = UUID(), title: String, url: String, icon: String? = nil) {
        self.id = id; self.title = title; self.url = url; self.icon = icon
    }

    /// Whether two addresses are the same page for "is it open": ignores the
    /// #fragment, a trailing slash, and the case of the scheme and host.
    public static func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }

    /// What two addresses of the same page share. Remembered per address
    /// (PageKeys), so asking again costs a lookup, not a parse.
    public static func key(_ s: String) -> String { PageKeys.key(s, compute: computeKey) }

    static func computeKey(_ s: String) -> String {
        guard var c = URLComponents(string: s) else { return s }
        c.fragment = nil
        c.scheme = c.scheme?.lowercased()
        c.host = c.host?.lowercased()
        if c.path.count > 1, c.path.hasSuffix("/") { c.path.removeLast() }
        if c.path.isEmpty { c.path = "/" }
        return c.string ?? s
    }
}

/// sidebar.json in the settings folder.
public struct SidebarStore: Sendable {
    public let file: URL

    public init(folder: SettingsFolder) { file = folder.directory.appendingPathComponent("sidebar.json") }
    public init(file: URL) { self.file = file }

    /// The saved library, or the starter one when there is no file. Throws
    /// when the file exists but is unsafe or unreadable.
    public func load() throws -> SidebarLibrary {
        guard FileManager.default.fileExists(atPath: file.path) else { return .starter }
        if let problem = FileSafety.problem(with: file) { throw ConfigError.unsafeFile("Refused sidebar.json: \(problem).") }
        let lib = try JSONDecoder().decode(SidebarLibrary.self, from: Data(contentsOf: file))
        return lib.profiles.isEmpty ? .starter : lib
    }

    /// Changes the library starting from what is on disk now.
    @discardableResult
    public func update(_ change: (inout SidebarLibrary) throws -> Void) throws -> SidebarLibrary {
        try SettingsFile.withLock(beside: file, name: ".sidebar.lock", what: "sidebar.json") {
            var lib = try load()
            try change(&lib)
            try SettingsFile.write(lib, to: file, what: "sidebar.json")
            return lib
        }
    }
}
