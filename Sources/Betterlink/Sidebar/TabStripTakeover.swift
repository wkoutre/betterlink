import ApplicationServices
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
        var done: [String] = []
        // 1. Vertical tabs on (a checkmark when on).
        if let show = find(in: bar, where: { $0.localizedCaseInsensitiveContains("tabs vertically") }) {
            if (copy(show.item, kAXMenuItemMarkCharAttribute as String) as String?)?.isEmpty ?? true {
                if AXUIElementPerformAction(show.item, kAXPressAction as CFString) == .success { done.append(show.title) }
            }
        }
        // 2. Collapsed: the item reads "Collapse Vertical Tabs" while expanded.
        if let collapse = find(in: bar, where: { $0.localizedCaseInsensitiveContains("collapse vertical tabs") }),
           (copy(collapse.item, kAXEnabledAttribute as String) as Bool?) ?? true,
           (copy(collapse.item, kAXMenuItemMarkCharAttribute as String) as String?)?.isEmpty ?? true {
            if AXUIElementPerformAction(collapse.item, kAXPressAction as CFString) == .success { done.append(collapse.title) }
        }
        return done.isEmpty ? nil : done.joined(separator: ", ")
    }

    private static func find(in e: AXUIElement, depth: Int = 0, where match: (String) -> Bool) -> (item: AXUIElement, title: String)? {
        if let t: String = copy(e, kAXTitleAttribute as String), match(t), (copy(e, kAXRoleAttribute as String) as String?) == kAXMenuItemRole as String {
            return (e, t)
        }
        guard depth < 4 else { return nil }
        for c in (copy(e, kAXChildrenAttribute as String) as [AXUIElement]?) ?? [] {
            if let hit = find(in: c, depth: depth + 1, where: match) { return hit }
        }
        return nil
    }

    private static func copy<T>(_ e: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }
}
