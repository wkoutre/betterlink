import Foundation

/// Which of a Chromium browser's menu items the tab takeover may press. Only
/// the View menu, and only these exact titles: other menus (History, Bookmarks,
/// Window) hold items titled by web pages, which must never choose an action.
public enum TabStripMenu {
    public static let menu = "View"
    public static let showVertically = "Show Tabs Vertically"
    public static let collapse = "Collapse Vertical Tabs"

    /// The index of the item titled `title` in the menu-bar menu titled
    /// "View", given every menu's title and its items' titles in order.
    public static func locate(_ title: String, in menus: [(title: String, items: [String])]) -> (menu: Int, item: Int)? {
        guard let m = menus.firstIndex(where: { $0.title == menu }),
              let i = menus[m].items.firstIndex(of: title) else { return nil }
        return (m, i)
    }
}
