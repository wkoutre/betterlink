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
    static func limitWaiting(on el: AXUIElement) { AXUIElementSetMessagingTimeout(el, Float(callLimit)) }
    nonisolated static let callLimit = 1.0

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

    /// Sends one of `WindowSteps`' calls.
    static func send(_ call: WindowSteps.Call, to win: WindowHandle) {
        guard let h = Displays.primaryHeight else { return }
        switch call {
        case .size(let f): win.setSize(f.size)
        case .position(let f): win.setPosition(SidebarGeometry.ax(fromCocoa: f, mainScreenHeight: h).origin)
        }
    }

    /// A window given its space back: the frame it takes, its browser's
    /// process (a browser that misses a call is asked nothing more), and the
    /// steps it was on: their call in flight is waited for first.
    struct Move {
        var window: WindowHandle
        var frame: CGRect
        var pid: pid_t
        var after: WindowSteps?
    }

    /// The longest quitting (or turning the sidebar off) holds the app up,
    /// however many windows there are and whatever their browsers do; and
    /// the longest one call to a browser may wait meanwhile.
    nonisolated static let placeBound = 4 * WindowSteps.timeout
    nonisolated static let placeCall = 0.2

    /// Moves each window to its frame now, for when there is no later (the
    /// app quitting, the sidebar turned off): its final target sent whole
    /// (`WindowSteps.resends`), so any call of betterlink's still on its way
    /// to it lands first. All the windows together, each call sent as soon
    /// as that window's last has landed, so the wait is that of the slowest
    /// window, not the sum of them all (review F3). Each call may wait
    /// `placeCall` for its browser, and none is sent that could end past
    /// `placeBound`: a browser that misses one (hung) is sent nothing more,
    /// for any of its windows, and what hasn't landed then is left as it is.
    /// Returns the windows whose browser missed. `clock` and `pause`: the
    /// time, and waiting (tests step their own).
    /// `hung`: browsers known not to answer, sent nothing. `began`: when the
    /// bound started (before this, when the caller spent some of it), and
    /// `reserve`: time the caller keeps for after.
    @discardableResult
    static func placeNow(_ moves: [Move], hung known: Set<pid_t> = [], began start: Double? = nil, reserve: Double = 0,
                         clock: () -> Double = CACurrentMediaTime, pause: (Double) -> Void = AXWindow.sleep) -> Set<ObjectIdentifier> {
        var all = moves.map { (move: $0, steps: WindowSteps(target: $0.frame, keep: nil, resends: true, after: $0.after), over: false) }
        var hung = known
        var missed: Set<ObjectIdentifier> = []
        for m in moves { m.window.limitWaiting(placeCall) }
        defer { for m in moves { m.window.limitWaiting(callLimit) } }
        let began = start ?? clock()
        while all.contains(where: { !$0.over }) {
            for k in all.indices where !all[k].over {
                let m = all[k].move
                if hung.contains(m.pid) {
                    missed.insert(ObjectIdentifier(m.window))
                    all[k].over = true
                    continue
                }
                // Out of time: left as it is. Gone: nothing to do.
                guard clock() - began + placeCall + reserve <= placeBound, let seen = shownFrame(of: m.window) else { all[k].over = true; continue }
                if let call = all[k].steps.step(seen: seen, now: clock()) {
                    send(call, to: m.window)
                    if m.window.missed {
                        hung.insert(m.pid)
                        missed.insert(ObjectIdentifier(m.window))
                        all[k].over = true
                        continue
                    }
                }
                all[k].over = all[k].steps.done
            }
            if all.contains(where: { !$0.over }) { pause(0.01) }
        }
        return missed
    }

    /// Waits `seconds` on this thread.
    nonisolated static func sleep(_ seconds: Double) { usleep(UInt32(max(0, seconds) * 1_000_000)) }

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
