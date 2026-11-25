import Foundation

/// One row of the sidebar, for the keyboard.
public enum SidebarRowID: Hashable, Sendable {
    case favorite(UUID)
    case folder(UUID)
    case link(UUID)
    case tab(Int)
}

/// The order the arrow keys move through the sidebar's rows. Pure, so it is
/// unit tested; the view draws the cursor and runs the actions.
public enum SidebarRows {
    /// The rows on screen, top to bottom: the Favorites, the saved items (a
    /// closed folder still lists its open links), then the window's own tabs.
    public static func visible(_ p: SidebarProfile, open: Set<UUID>, tabs: [Int]) -> [SidebarRowID] {
        func walk(_ items: [SidebarItem]) -> [SidebarRowID] {
            items.flatMap { item -> [SidebarRowID] in
                switch item {
                case .link(let l): return [.link(l.id)]
                case .folder(let f):
                    let inside = f.expanded ? walk(f.items)
                        : SidebarProfile.links(in: f.items).filter { open.contains($0.id) }.map { .link($0.id) }
                    return [.folder(f.id)] + inside
                }
            }
        }
        return p.favorites.map { .favorite($0.id) } + walk(p.items) + tabs.map { .tab($0) }
    }

    /// The row `step` rows away, stopping at the ends. With no cursor yet:
    /// the first row going down, the last going up.
    public static func move(_ cursor: SidebarRowID?, by step: Int, in rows: [SidebarRowID]) -> SidebarRowID? {
        guard !rows.isEmpty else { return nil }
        guard let cursor, let i = rows.firstIndex(of: cursor) else { return step > 0 ? rows.first : rows.last }
        return rows[min(max(i + step, 0), rows.count - 1)]
    }

    /// The cursor after the rows changed: the same row while it is there, else
    /// the row now in its place (the next one, after a delete).
    public static func keep(_ cursor: SidebarRowID?, from old: [SidebarRowID], to new: [SidebarRowID]) -> SidebarRowID? {
        guard let cursor else { return nil }
        if new.contains(cursor) { return cursor }
        guard let i = old.firstIndex(of: cursor), !new.isEmpty else { return nil }
        return new[min(i, new.count - 1)]
    }
}
