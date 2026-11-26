import ApplicationServices

/// One walk over a browser window's own chrome for its tab groups and
/// toolbars: a few dozen elements, pages skipped. The tab takeover (where the
/// tab strip is, `TabStripTakeover.read`) and the kind of window it is
/// (`AXWindow.tabs(in:)`) both read a window through this one walk, so the two
/// can't come to see different windows.
///
/// No element waits more than a second for its answer, and a browser that
/// doesn't answer is not asked for the rest.
@MainActor
final class ChromeWalk {
    /// False once a call got no answer in time.
    private(set) var answered = true
    /// Round trips to the browser so far.
    private(set) var calls = 0
    private var seen = 0

    /// Role, subrole and children in one round trip to the browser.
    private func parts(_ e: AXUIElement) -> (role: String, subrole: String, children: [AXUIElement])? {
        AXWindow.limitWaiting(on: e)
        var values: CFArray?
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXChildrenAttribute] as CFArray
        calls += 1
        let answer = AXUIElementCopyMultipleAttributeValues(e, names, [], &values)
        if answer == .cannotComplete { answered = false }
        guard answer == .success, let v = values as? [Any], v.count == 3 else { return nil }
        return (v[0] as? String ?? "", v[1] as? String ?? "", v[2] as? [AXUIElement] ?? [])
    }

    /// Hands `found` each tab group and toolbar of `window` with its children,
    /// outermost first and without looking inside one. `found` says whether to
    /// go on. False when the window couldn't be read, or its browser stopped
    /// answering before the end: what was found then is not the whole window.
    func run(_ window: AXUIElement, found: (_ role: String, _ element: AXUIElement, _ children: [AXUIElement]) -> Bool) -> Bool {
        var readWindow = false, stopped = false
        func walk(_ e: AXUIElement, _ depth: Int) {
            seen += 1
            guard !stopped, answered, depth < 14, seen < 1500, let p = parts(e) else { return }
            if depth == 0 { readWindow = true }
            if p.role == "AXWebArea" { return }
            if p.role == kAXTabGroupRole as String || p.role == kAXToolbarRole as String {
                if !found(p.role, e, p.children) { stopped = true }
                return
            }
            for c in p.children { walk(c, depth + 1) }
        }
        walk(window, 0)
        return readWindow && answered
    }

    /// The first tab (an AXTabButton) under a tab group's children that
    /// `accept` takes.
    func firstTab(in children: [AXUIElement], where accept: (AXUIElement) -> Bool = { _ in true }) -> AXUIElement? {
        func search(_ children: [AXUIElement], _ depth: Int) -> AXUIElement? {
            guard depth < 6 else { return nil }
            for c in children {
                seen += 1
                guard answered, seen < 1500, let p = parts(c), p.role != "AXWebArea" else { continue }
                if p.subrole == "AXTabButton", accept(c) { return c }
                if let tab = search(p.children, depth + 1) { return tab }
            }
            return nil
        }
        return search(children, 0)
    }
}
