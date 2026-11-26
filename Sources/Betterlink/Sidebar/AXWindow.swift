import AppKit
import ApplicationServices
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

    static func frame(of win: WindowHandle) -> CGRect? {
        guard let p = win.position(), let s = win.size(), let mainHeight = Displays.primaryHeight else { return nil }
        return SidebarGeometry.cocoa(fromAX: CGRect(origin: p, size: s), mainScreenHeight: mainHeight)
    }

    /// Window's frame as the window server shows it now, Cocoa coordinates.
    /// Cheap enough to call every frame.
    static func shownFrame(of win: WindowHandle) -> CGRect? {
        guard let b = win.shownBounds(), let h = Displays.primaryHeight else { return nil }
        return SidebarGeometry.cocoa(fromAX: b, mainScreenHeight: h)
    }

    static func setFrame(_ frame: CGRect, of win: WindowHandle) {
        guard let h = Displays.primaryHeight else { return }
        let ax = SidebarGeometry.ax(fromCocoa: frame, mainScreenHeight: h)
        // Size, position, size: macOS limits each step to what fits on screen
        // at that moment, so a move that needs the new size comes after it.
        win.setSize(ax.size)
        win.setPosition(ax.origin)
        win.setSize(ax.size)
    }

    /// One step of a slide: the size, and the position too when the window's
    /// left edge moves (the sidebar on the left), so a frame costs one or two
    /// Accessibility calls rather than three. macOS limits each step to what
    /// fits on screen, so a growing window moves first and a shrinking one
    /// resizes first.
    static func slide(_ win: WindowHandle, to frame: CGRect, moveOrigin: Bool, growing: Bool) {
        guard let h = Displays.primaryHeight else { return }
        let ax = SidebarGeometry.ax(fromCocoa: frame, mainScreenHeight: h)
        var origin = ax.origin
        func move() { if moveOrigin { win.setPosition(origin) } }
        func resize() { win.setSize(ax.size) }
        // The far edge must not move: the origin goes where the width the window
        // really has leaves it. A browser that is slow to narrow (or won't) is
        // then simply not moved yet, never pushed off the screen.
        func keepFarEdge() {
            guard moveOrigin, let real = win.size() else { return }
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

    /// Whether the window is a main browser window. A save panel, an
    /// extension's popup, a menu or a dialog isn't one.
    static func isMain(_ w: AXUIElement) -> Bool {
        let role: String? = copy(w, kAXRoleAttribute), subrole: String? = copy(w, kAXSubroleAttribute)
        guard role == (kAXWindowRole as String), subrole == (kAXStandardWindowSubrole as String) else { return false }
        let minimize: AXUIElement? = copy(w, kAXMinimizeButtonAttribute)
        let fullScreen: AXUIElement? = copy(w, kAXFullScreenButtonAttribute)
        return minimize != nil && fullScreen != nil
    }

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

    /// Every window of the processes `pids`, on every Space and at every layer:
    /// all the window server tells without Screen Recording (no titles). A
    /// few milliseconds for a few hundred windows, so read on window and app
    /// events only. Nil when the window server gives no list.
    static func windows(of pids: Set<Int>) -> [WindowPairing.ServerWindow]? {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? Int, pids.contains(pid), let n = number(info),
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let b = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
            return .init(number: n, pid: pid, layer: layer, bounds: WindowBounds(left: b.minX, top: b.minY, width: b.width, height: b.height))
        }
    }

    /// Window `n`'s bounds right now (what is on screen), Accessibility
    /// coordinates. Cheap enough to call every frame.
    static func bounds(_ n: UInt32) -> CGRect? {
        guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], n) as? [[String: Any]])?.first else { return nil }
        return (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }

    /// Window `n`'s frame right now (what is on screen), Cocoa coordinates.
    static func frame(_ n: UInt32) -> CGRect? {
        guard let b = bounds(n), let h = Displays.primaryHeight else { return nil }
        return SidebarGeometry.cocoa(fromAX: b, mainScreenHeight: h)
    }

    private static func number(_ info: [String: Any]) -> UInt32? { (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
}
