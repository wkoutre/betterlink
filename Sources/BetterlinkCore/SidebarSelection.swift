import Foundation

/// The rows picked in one sidebar for an action on all of them, as in Finder
/// and a browser's tab strip: Command-click adds a row or takes it out,
/// Shift-click takes every row from the last one clicked to this one. Pure,
/// so it is unit tested; the view draws it and runs the actions.
public struct SidebarSelection: Equatable, Sendable {
    public private(set) var rows: Set<SidebarRowID> = []
    /// Where a Shift-click's range starts: the row last clicked.
    public private(set) var anchor: SidebarRowID?

    public init() {}

    public var isEmpty: Bool { rows.isEmpty }
    public var count: Int { rows.count }
    public func contains(_ row: SidebarRowID) -> Bool { rows.contains(row) }

    /// A plain click: nothing stays picked, and a range would start here.
    public mutating func click(_ row: SidebarRowID) {
        rows = []
        anchor = row
    }

    /// Nothing picked. The range's start stays where it was.
    public mutating func clear() { rows = [] }

    /// Command-click: `row` joins the picked rows, or leaves them. With none
    /// picked yet, the row of the tab you are on (`current`) counts as picked
    /// first, as the active tab does in a browser's tab strip and the
    /// highlighted file does in Finder; Command-click it to take it out.
    public mutating func toggle(_ row: SidebarRowID, current: SidebarRowID?, in visible: [SidebarRowID]) {
        guard visible.contains(row) else { return }
        if rows.isEmpty, let current, current != row, visible.contains(current) { rows = [current] }
        if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
        anchor = row
    }

    /// Shift-click: every row on screen from where the range starts to `row`,
    /// both included, replaces what was picked. The range starts at the row
    /// last clicked while it is on screen, else at the tab you are on, else
    /// at `row` itself. It stays there, so another Shift-click changes where
    /// the same range ends.
    public mutating func extend(to row: SidebarRowID, current: SidebarRowID?, in visible: [SidebarRowID]) {
        guard let to = visible.firstIndex(of: row) else { return }
        let start = [anchor, current].compactMap { $0 }.first { visible.contains($0) } ?? row
        let from = visible.firstIndex(of: start) ?? to
        rows = Set(visible[min(from, to)...max(from, to)])
        anchor = start
    }

    /// After the rows on screen changed: a row no longer there (its tab
    /// closed, its folder closed over it) is no longer picked.
    public func kept(in visible: [SidebarRowID]) -> SidebarSelection {
        var s = self
        let there = Set(visible)
        s.rows = rows.intersection(there)
        if let a = anchor, !there.contains(a) { s.anchor = nil }
        return s
    }

    /// The picked rows, top to bottom.
    public func ordered(in visible: [SidebarRowID]) -> [SidebarRowID] {
        visible.filter(rows.contains)
    }

    /// What the picked rows are, for the actions on them.
    public struct Parts: Equatable, Sendable {
        /// The window's own tabs (the rows no saved link holds), top to bottom.
        public var tabs: [Int] = []
        /// The Favorites, saved links and folders, top to bottom, without
        /// those inside a picked folder: that folder carries them.
        public var saved: [UUID] = []
        /// Every saved link among them, those inside picked folders included.
        public var links: [SavedLink] = []
        /// Whether a folder is among `saved`, and whether one has things in it.
        public var hasFolder = false
        public var hasFullFolder = false

        public var isEmpty: Bool { tabs.isEmpty && saved.isEmpty }
    }

    public func parts(in visible: [SidebarRowID], of p: SidebarProfile) -> Parts {
        var out = Parts()
        var ids: [UUID] = []
        for row in ordered(in: visible) {
            switch row {
            case .tab(let id): out.tabs.append(id)
            case .favorite(let id), .folder(let id), .link(let id): ids.append(id)
            }
        }
        out.saved = p.roots(of: ids)
        for id in out.saved {
            if let l = p.favorites.first(where: { $0.id == id }) { out.links.append(l); continue }
            switch SidebarProfile.find(id, in: p.items) {
            case .link(let l)?: out.links.append(l)
            case .folder(let f)?:
                out.hasFolder = true
                if !f.items.isEmpty { out.hasFullFolder = true }
                out.links += SidebarProfile.links(in: f.items)
            case nil: break
            }
        }
        return out
    }
}

extension SidebarRows {
    /// The row of the tab the window shows: its own row, or the Favorite or
    /// saved link holding it. Nil when that row isn't on screen.
    public static func current(in rows: [SidebarRowID], activeTab: Int?, activeLinks: Set<UUID>) -> SidebarRowID? {
        rows.first { row in
            switch row {
            case .tab(let id): return id == activeTab
            case .favorite(let id), .link(let id): return activeLinks.contains(id)
            case .folder: return false
            }
        }
    }
}
