import ApplicationServices
import BetterlinkCore
import Foundation

/// "The sidebar takes over the tabs": in a Chromium browser that has vertical
/// tabs (Chrome 158: View › Show Tabs Vertically, Collapse Vertical Tabs), the
/// browser's own tab strip is switched to vertical and collapsed, the closest
/// a browser lets anything come to hiding it. No browser has an extension API
/// for this, so it uses the browser's own menu items through Accessibility,
/// and only when they are not already in that state. The setting is per
/// browser profile, so it is checked on every window the sidebar binds to.
@MainActor
enum TabStripTakeover {
    /// What was done, for the log and the tests: nil when nothing was needed.
    @discardableResult
    static func apply(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = copy(app, kAXMenuBarAttribute as String) else { return nil }
        // Each menu-bar menu with its items' titles; only the View menu's exact
        // titles are ever pressed (TabStripMenu), never a page-titled item.
        let menus: [(title: String, items: [AXUIElement])] = children(bar).map { top in
            (copy(top, kAXTitleAttribute as String) ?? "", children(top).flatMap(children))
        }
        let titled = menus.map { (title: $0.title, items: $0.items.map { copy($0, kAXTitleAttribute as String) ?? "" }) }
        func item(_ title: String) -> AXUIElement? {
            TabStripMenu.locate(title, in: titled).map { menus[$0.menu].items[$0.item] }
        }
        var done: [String] = []
        // 1. Vertical tabs on (a checkmark when on).
        if let show = item(TabStripMenu.showVertically),
           (copy(show, kAXMenuItemMarkCharAttribute as String) as String?)?.isEmpty ?? true,
           AXUIElementPerformAction(show, kAXPressAction as CFString) == .success {
            done.append(TabStripMenu.showVertically)
        }
        // 2. Collapsed (a checkmark when collapsed; enabled only once vertical).
        if let collapse = item(TabStripMenu.collapse),
           (copy(collapse, kAXEnabledAttribute as String) as Bool?) ?? true,
           (copy(collapse, kAXMenuItemMarkCharAttribute as String) as String?)?.isEmpty ?? true,
           AXUIElementPerformAction(collapse, kAXPressAction as CFString) == .success {
            done.append(TabStripMenu.collapse)
        }
        return done.isEmpty ? nil : done.joined(separator: ", ")
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        (copy(e, kAXChildrenAttribute as String) as [AXUIElement]?) ?? []
    }

    private static func copy<T>(_ e: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }
}
