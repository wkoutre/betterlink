import AppKit
import ApplicationServices
import BetterlinkCore
import TabSyncCore

/// Reading and moving another app's windows through Accessibility. Frames are
/// Cocoa global coordinates.
@MainActor
enum AXWindow {
    static func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        let answer = AXUIElementCopyAttributeValue(el, attr as CFString, &v)
        timedOut = answer == .cannotComplete
        guard answer == .success, let v else { return nil }
        return v as? T
    }

    /// Whether the last `copy` got no answer in time: its app is hung or busy.
    private(set) static var timedOut = false

    /// How long one call to a browser may wait. The default is several
    /// seconds, on the main thread, for each call a hung browser doesn't
    /// answer. Set on every element kept or asked more than once: per the
    /// header it holds for that object only, not for others equal to it.
    static func limitWaiting(on el: AXUIElement) { AXUIElementSetMessagingTimeout(el, 1) }

    static func frame(of win: AXUIElement) -> CGRect? {
        guard let pv: AXValue = copy(win, kAXPositionAttribute), let sv: AXValue = copy(win, kAXSizeAttribute),
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return SidebarGeometry.cocoa(fromAX: CGRect(origin: p, size: s), mainScreenHeight: mainHeight)
    }

    static func setFrame(_ frame: CGRect, of win: AXUIElement) {
        guard let h = NSScreen.screens.first?.frame.height else { return }
        let ax = SidebarGeometry.ax(fromCocoa: frame, mainScreenHeight: h)
        var origin = ax.origin, size = ax.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        // Size, position, size: macOS limits each step to what fits on screen
        // at that moment, so a move that needs the new size comes after it.
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
    }

    /// One step of a slide: the size, and the position too when the window's
    /// left edge moves (the sidebar on the left), so a frame costs one or two
    /// Accessibility calls rather than three. macOS limits each step to what
    /// fits on screen, so a growing window moves first and a shrinking one
    /// resizes first.
    static func slide(_ win: AXUIElement, to frame: CGRect, moveOrigin: Bool, growing: Bool) {
        guard let h = NSScreen.screens.first?.frame.height else { return }
        let ax = SidebarGeometry.ax(fromCocoa: frame, mainScreenHeight: h)
        var origin = ax.origin, size = ax.size
        func move() { if moveOrigin, let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p) } }
        func resize() { if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s) } }
        // The far edge must not move: the origin goes where the width the window
        // really has leaves it. A browser that is slow to narrow (or won't) is
        // then simply not moved yet, never pushed off the screen.
        func keepFarEdge() {
            guard moveOrigin, let sv: AXValue = copy(win, kAXSizeAttribute) else { return }
            var real = CGSize.zero
            guard AXValueGetValue(sv, .cgSize, &real) else { return }
            origin.x = ax.maxX - real.width
        }
        if growing {
            move(); resize()
            // Moved again only if the browser has not widened as far as asked.
            let asked = origin.x
            keepFarEdge()
            if abs(origin.x - asked) >= 1 { move() }
        } else {
            resize(); keepFarEdge(); move()
        }
    }

    /// Brings the window in front of its app's other windows.
    static func raise(_ win: AXUIElement) {
        AXUIElementPerformAction(win, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(win, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    /// Whether the window is a standard one with a title bar's buttons. A save
    /// panel, a menu or a dialog isn't. A browser window is, and so are an
    /// extension's palette, an app window and DevTools on its own: which of
    /// those it is, is read from what it holds (`tabs(in:)`, `WindowKinds`).
    static func isMain(_ w: AXUIElement) -> Bool {
        let role: String? = copy(w, kAXRoleAttribute), subrole: String? = copy(w, kAXSubroleAttribute)
        guard role == (kAXWindowRole as String), subrole == (kAXStandardWindowSubrole as String) else { return false }
        let minimize: AXUIElement? = copy(w, kAXMinimizeButtonAttribute)
        let fullScreen: AXUIElement? = copy(w, kAXFullScreenButtonAttribute)
        return minimize != nil && fullScreen != nil
    }

    /// One look at what a window holds, for `WindowKinds`: its tab groups and
    /// whether one has a tab in it, by the walk the tab takeover reads the
    /// window with (`ChromeWalk`). Stops at the first tab. Nil when the window
    /// can't be read now: it is gone, or its browser didn't answer in time
    /// (`timedOut`).
    static func tabs(in win: AXUIElement) -> WindowKinds.Reading? {
        var reading = WindowKinds.Reading(tabGroups: 0, tabs: 0)
        let walk = ChromeWalk()
        let began = CACurrentMediaTime()
        let read = walk.run(win) { role, _, children in
            guard role == kAXTabGroupRole as String else { return true }
            reading.tabGroups += 1
            guard walk.firstTab(in: children) != nil else { return true }
            reading.tabs = 1
            return false
        }
        timedOut = !walk.answered
        lastWalk = (walk.calls, (CACurrentMediaTime() - began) * 1000)
        return read ? reading : nil
    }

    /// What the last `tabs(in:)` cost: round trips to the browser, and
    /// milliseconds on the main thread. For the trace.
    private(set) static var lastWalk = (calls: 0, ms: 0.0)

    /// The window's window-server number. Accessibility has no public way to
    /// tell it, and the frame can't: two windows of one browser often share
    /// one, and then the wrong window's sidebar would be moved and ordered.
    /// Nil should macOS ever drop the function: then no window gets a sidebar
    /// (`numbersWindows`; the Sidebar page and `sidebar settings get` say so).
    static func number(of win: AXUIElement) -> CGWindowID? {
        var n = CGWindowID(0)
        guard let get = getWindow, get(win, &n) == .success, n != 0 else { return nil }
        return n
    }

    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    nonisolated private static let getWindow: GetWindow? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow")
        .map { unsafeBitCast($0, to: GetWindow.self) }

    /// Whether this macOS still has the function `number(of:)` needs.
    nonisolated static var numbersWindows: Bool { getWindow != nil }
}

/// What the window server knows about every app's windows: numbers, frames and
/// layers only, which need no Screen Recording permission (names would).
@MainActor
enum WindowServer {
    /// The windows on screen at the normal level, front to back: on a Space
    /// that is showing, not minimized, their app not hidden.
    static func onScreen() -> [UInt32] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.filter { $0[kCGWindowLayer as String] as? Int == 0 }.compactMap(number)
    }

    /// Every window there is (any app, any Space, minimized too).
    static func all() -> Set<UInt32> {
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return Set(list.compactMap(number))
    }

    /// Window `n`'s frame right now (what is on screen), Cocoa coordinates.
    /// Cheap enough to call every frame.
    static func frame(_ n: UInt32) -> CGRect? {
        guard let h = NSScreen.screens.first?.frame.height,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], n) as? [[String: Any]])?.first,
              let b = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
        return SidebarGeometry.cocoa(fromAX: b, mainScreenHeight: h)
    }

    private static func number(_ info: [String: Any]) -> UInt32? { (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
}
