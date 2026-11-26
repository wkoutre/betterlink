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

    /// Sets only what differs: the size, the position, or (both differing)
    /// the size and then the position. On macOS 27 each set is animated and
    /// the next one cuts it short, so where both change and must land,
    /// `WindowSteps` sends them one at a time instead.
    static func setFrame(_ frame: CGRect, of win: WindowHandle) {
        guard let h = Displays.primaryHeight else { return }
        let ax = SidebarGeometry.ax(fromCocoa: frame, mainScreenHeight: h)
        let now = Self.frame(of: win)
        if now.map({ abs($0.width - frame.width) >= 0.5 || abs($0.height - frame.height) >= 0.5 }) ?? true { win.setSize(ax.size) }
        if now.map({ abs($0.minX - frame.minX) >= 0.5 || abs($0.maxY - frame.maxY) >= 0.5 }) ?? true { win.setPosition(ax.origin) }
    }

    /// Sends one of `WindowSteps`' calls.
    static func send(_ call: WindowSteps.Call, to win: WindowHandle) {
        guard let h = Displays.primaryHeight else { return }
        switch call {
        case .size(let f): win.setSize(f.size)
        case .position(let f): win.setPosition(SidebarGeometry.ax(fromCocoa: f, mainScreenHeight: h).origin)
        }
    }

    /// Moves the window to `frame` one call at a time, each waited for on
    /// screen, now: for when there is no later (the app quitting). At most
    /// `WindowSteps.timeout` a call.
    static func placeNow(_ win: WindowHandle, to frame: CGRect, keep side: SidebarSide?) {
        var steps = WindowSteps(target: frame, keep: side)
        let began = CACurrentMediaTime()
        while !steps.done, CACurrentMediaTime() - began < 4 * WindowSteps.timeout {
            guard let seen = shownFrame(of: win) ?? Self.frame(of: win) else { return }
            if let call = steps.step(seen: seen, now: CACurrentMediaTime()) { send(call, to: win) }
            usleep(10_000)
        }
    }

    /// One step of a drag of the sidebar's edge, where the pointer leads each
    /// step: keeps the window's far edge (the one away from the sidebar, on
    /// `side`) where `frame` has it. The size, and the position too when it
    /// moves (`moveOrigin`), so a step costs one to three Accessibility calls.
    /// macOS limits each step to what fits on screen, so a growing window
    /// moves first and a shrinking one resizes first.
    static func slide(_ win: WindowHandle, to frame: CGRect, side: SidebarSide, moveOrigin: Bool, growing: Bool) {
        guard let h = Displays.primaryHeight else { return }
        let ax = SidebarGeometry.ax(fromCocoa: frame, mainScreenHeight: h)
        var origin = ax.origin
        func move() { if moveOrigin { win.setPosition(origin) } }
        func resize() { win.setSize(ax.size) }
        // The far edge must not move: the origin goes where the width the window
        // really has leaves it. A browser that is slow to narrow (or won't) is
        // then simply not moved yet, never pushed off the screen; one whose
        // width can't be read isn't moved either. False then.
        func keepFarEdge() -> Bool {
            guard moveOrigin else { return false }
            guard side == .left else { return true } // the far edge is the origin, where asked
            // The width on screen: Accessibility can read back a size the
            // browser never took (Nick's Brave on 0.3.18).
            guard let real = win.shownBounds()?.size ?? win.size() else { return false }
            origin.x = ax.maxX - real.width
            return true
        }
        if growing {
            move(); resize()
            // Moved again only if the browser has not widened as far as asked.
            let asked = origin.x
            if keepFarEdge(), abs(origin.x - asked) >= 1 { move() }
        } else {
            resize()
            if keepFarEdge() { move() }
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

    // MARK: - Corner radius

    /// The radius the window server rounds window `n`'s corners with, in
    /// points, or nil when it can't be asked or gives no sane answer
    /// (`SidebarSeam.radius(reported:)`). Each window has its own: on macOS
    /// 26.5 a Chrome or Brave window reads 20, Dia 16, System Settings 26.
    /// Needs no permission. One round trip to the window server: asked when a
    /// window is first followed, when it enters or leaves full screen and
    /// each time it comes to rest, never per frame.
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
    /// on this Mac: its macOS is one the calls were verified on, all of them
    /// are there (they are looked up on Apple silicon only), and the fallback
    /// isn't forced. False: every sidebar is cut for
    /// `SidebarSeam.fallbackRadius`. One window's unusable answer doesn't
    /// change it; the trace has that.
    nonisolated static var readsCorners: Bool { skyLight != nil }

    /// Why it can't, for the trace.
    nonisolated static var cornersUnreadBecause: String? {
        if forcedFallback { return "BETTERLINK_CORNER_FALLBACK is set" }
        if !SidebarSeam.verifiedSystems.contains(ProcessInfo.processInfo.operatingSystemVersion.majorVersion) {
            return "the window server's corner radius was not verified on macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        }
        return skyLight == nil ? "the call for a window's corner radius can't be found on this Mac" : nil
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
