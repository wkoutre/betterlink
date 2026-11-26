import ApplicationServices
import BetterlinkCore
import Foundation

/// "The sidebar takes over the tabs": in a Chromium browser that has vertical
/// tabs (Chrome 158: View › Show Tabs Vertically, Collapse Vertical Tabs; Brave
/// has the first), the browser's own tab strip is switched to vertical and
/// collapsed, the closest a browser lets anything come to hiding it. No
/// browser has an extension API for this, so it uses the browser's own menu
/// items through Accessibility.
///
/// What state the tabs are in is read from the window itself, where the tab
/// strip is beside the toolbar (`TabStripReading`), never from the menu alone:
/// Brave's item has no checkmark, on or off.
@MainActor
enum TabStripTakeover {
    /// The window's tab strip and toolbar, and the two View menu items.
    static func read(pid: pid_t, window: AXUIElement) -> TabStripReading {
        let items = menuItems(pid: pid)
        func item(_ e: AXUIElement?) -> TabStripReading.Item? {
            e.map { .init(enabled: copy($0, kAXEnabledAttribute as String), mark: copy($0, kAXMenuItemMarkCharAttribute as String)) }
        }
        // A browser without the item (Arc, Dia) can't be taken over: its window is not walked.
        guard items.show != nil else { return TabStripReading(tabs: nil, toolbar: nil, tabHeight: nil, show: nil, collapse: nil) }
        var groups: [(frame: CGRect, tabHeight: CGFloat)] = [], toolbars: [CGRect] = []
        // The walk that also says what kind of window it is (ChromeWalk): the
        // browser's own chrome, a few hundred elements at most, pages skipped.
        let walk = ChromeWalk()
        let read = walk.run(window) { role, e, children in
            guard let f = frame(e) else { return true }
            if role == kAXTabGroupRole as String {
                var height: CGFloat = 0
                let tab = walk.firstTab(in: children) { height = frame($0)?.height ?? 0; return height > 0 }
                if tab != nil { groups.append((f, height)) }
            } else if holdsTextField(e, depth: 0) {
                toolbars.append(f)
            }
            return true
        }
        // A browser that stopped answering partway was not seen whole.
        if !read { groups = []; toolbars = [] }
        // Exactly one of each, or it isn't known which is the window's own.
        return TabStripReading(tabs: groups.count == 1 ? groups[0].frame : nil, toolbar: toolbars.count == 1 ? toolbars[0] : nil,
                               tabHeight: groups.count == 1 ? groups[0].tabHeight : nil,
                               show: item(items.show), collapse: item(items.collapse))
    }

    /// Presses the View menu item. False when it isn't there or the press failed.
    static func press(_ press: TabStripReading.Press, pid: pid_t) -> Bool {
        let items = menuItems(pid: pid)
        guard let item = press == .showVertically ? items.show : items.collapse else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    /// Only the View menu's exact titles (TabStripMenu), never a page-titled
    /// item; only that menu's items are read.
    private static func menuItems(pid: pid_t) -> (show: AXUIElement?, collapse: AXUIElement?) {
        let app = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = copy(app, kAXMenuBarAttribute as String),
              let view = children(bar).first(where: { (copy($0, kAXTitleAttribute as String) as String?) == TabStripMenu.menu }) else { return (nil, nil) }
        let items = children(view).flatMap(children)
        let titled = [(title: TabStripMenu.menu, items: items.map { copy($0, kAXTitleAttribute as String) ?? "" })]
        func item(_ title: String) -> AXUIElement? { TabStripMenu.locate(title, in: titled).map { items[$0.item] } }
        return (item(TabStripMenu.showVertically), item(TabStripMenu.collapse))
    }

    private static func holdsTextField(_ e: AXUIElement, depth: Int) -> Bool {
        guard depth < 6 else { return false }
        return children(e).contains {
            (copy($0, kAXRoleAttribute as String) as String?) == kAXTextFieldRole as String || holdsTextField($0, depth: depth + 1)
        }
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p: AXValue = copy(e, kAXPositionAttribute as String), let s: AXValue = copy(e, kAXSizeAttribute as String) else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p, .cgPoint, &origin), AXValueGetValue(s, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
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
