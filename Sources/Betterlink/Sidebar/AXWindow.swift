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

    /// Window `n`'s frame right now (what is on screen), Cocoa coordinates.
    /// Cheap enough to call every frame.
    static func frame(_ n: UInt32) -> CGRect? {
        guard let h = NSScreen.screens.first?.frame.height,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], n) as? [[String: Any]])?.first,
              let b = (info[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return nil }
        return SidebarGeometry.cocoa(fromAX: b, mainScreenHeight: h)
    }

    private static func number(_ info: [String: Any]) -> UInt32? { (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value }

    // MARK: - Corner radius

    /// The radius the window server rounds window `n`'s corners with, in
    /// points, or nil when it can't be asked or gives no sane answer
    /// (`SidebarSeam.radius(reported:)`). Each window has its own: on macOS
    /// 26.5 a Chrome or Brave window reads 20, Dia 16, System Settings 26.
    /// Needs no permission. One round trip to the window server: asked when a
    /// window is first followed and when it changes display or leaves full
    /// screen, never per frame.
    ///
    /// No public API tells it. These are private SkyLight calls, looked up by
    /// name and never linked (as `_AXUIElementGetWindow` is), so a macOS
    /// without any of them falls back:
    ///
    ///     int       SLSMainConnectionID(void);
    ///     CFTypeRef SLSWindowQueryWindows(int cid, CFArrayRef numbers, int count);  // of CFNumber (SInt32); +1
    ///     CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef query);               // +1
    ///     bool      SLSWindowIteratorAdvance(CFTypeRef iterator);
    ///     uint32_t  SLSWindowIteratorGetWindowID(CFTypeRef iterator);
    ///     struct of doubles SLSWindowIteratorGetCornerRadii(CFTypeRef iterator);
    ///
    /// Verified on macOS 26.5.2 only (2026-11-25): a C probe declaring the
    /// last as returning four doubles printed `radii 20.00 20.00 0.00 0.00`
    /// for Chrome and 16 and 26 for other apps' windows, each matching the
    /// corner drawn in a capture of that window. The first double is taken
    /// (in d0 on arm64, whether the struct has two doubles or four). On any
    /// other macOS major version the calls are not made
    /// (`SidebarSeam.verifiedSystems`).
    static func cornerRadius(_ n: UInt32) -> CGFloat? {
        guard let sky = skyLight else { return nil }
        let numbers = [NSNumber(value: Int32(bitPattern: n))] as CFArray
        guard let query = sky.query(sky.connection(), numbers, 1)?.takeRetainedValue(),
              let windows = sky.windows(query)?.takeRetainedValue() else { return nil }
        while sky.advance(windows) {
            guard sky.id(windows) == n else { continue }
            return SidebarSeam.radius(reported: sky.radii(windows).x)
        }
        return nil
    }

    /// Whether the window server can be asked for a window's corner radius
    /// here. False: every sidebar is cut for `SidebarSeam.fallbackRadius`.
    nonisolated static var readsCorners: Bool { skyLight != nil }

    /// Why it can't, for the trace.
    nonisolated static var cornersUnreadBecause: String? {
        if forcedFallback { return "BETTERLINK_CORNER_FALLBACK is set" }
        if !SidebarSeam.verifiedSystems.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            return "the window server's corner radius was not verified on macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        }
        return skyLight == nil ? "this macOS has no call for a window's corner radius" : nil
    }

    /// For a capture of the fallback's corners beside a real window's:
    /// `BETTERLINK_CORNER_FALLBACK=1`, only in a run with its own
    /// `BETTERLINK_HOME` (a development run).
    nonisolated private static let forcedFallback: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["BETTERLINK_CORNER_FALLBACK"] == "1" && env["BETTERLINK_HOME"] != nil
    }()

    private struct SkyLight: @unchecked Sendable {
        let connection: @convention(c) () -> Int32
        let query: @convention(c) (Int32, CFArray, Int32) -> Unmanaged<AnyObject>?
        let windows: @convention(c) (AnyObject) -> Unmanaged<AnyObject>?
        let advance: @convention(c) (AnyObject) -> Bool
        let id: @convention(c) (AnyObject) -> UInt32
        let radii: @convention(c) (AnyObject) -> CGPoint
    }

    /// Nil unless every call is there, on a macOS they were verified on.
    nonisolated private static let skyLight: SkyLight? = {
        #if arch(arm64)
        guard !forcedFallback,
              SidebarSeam.verifiedSystems.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) else { return nil }
        func find<T>(_ name: String, _: T.Type) -> T? {
            dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let connection = find("SLSMainConnectionID", (@convention(c) () -> Int32).self),
              let query = find("SLSWindowQueryWindows", (@convention(c) (Int32, CFArray, Int32) -> Unmanaged<AnyObject>?).self),
              let windows = find("SLSWindowQueryResultCopyWindows", (@convention(c) (AnyObject) -> Unmanaged<AnyObject>?).self),
              let advance = find("SLSWindowIteratorAdvance", (@convention(c) (AnyObject) -> Bool).self),
              let id = find("SLSWindowIteratorGetWindowID", (@convention(c) (AnyObject) -> UInt32).self),
              let radii = find("SLSWindowIteratorGetCornerRadii", (@convention(c) (AnyObject) -> CGPoint).self) else { return nil }
        return SkyLight(connection: connection, query: query, windows: windows, advance: advance, id: id, radii: radii)
        #else
        return nil
        #endif
    }()
}
