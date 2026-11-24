import AppKit
import ApplicationServices
import BetterlinkCore
import TabSyncCore

/// Follows the frontmost browser window: which one it is, and its frame, the
/// moment either changes. Event-driven throughout:
///
/// - NSWorkspace tells us when another app comes to the front.
/// - An AXObserver on that app tells us when its focused window changes, moves,
///   resizes, minimises or goes full screen.
/// - During a live drag the frame comes from the window server, not from the
///   browser (an Accessibility read waits for the browser's busy main thread):
///   on every mouse-drag event, and once per display refresh until mouse up.
///
/// Needs the Accessibility permission (System Settings › Privacy & Security ›
/// Accessibility). Without it, `isTrusted` is false and nothing is reported.
@MainActor
final class WindowTracker: NSObject {
    struct Target: Equatable {
        var pid: pid_t
        var bundleId: String
        var appName: String
        /// The window's title (Chromium: the active tab's title).
        var title: String
        /// Cocoa global coordinates.
        var frame: CGRect
        var fullScreen: Bool
        /// Identity of the AX window, to tell "same window moved" from "another window".
        var windowHash: Int
    }

    /// Called with the current target, or nil when no browser window is in front.
    var onChange: ((Target?) -> Void)?
    /// Called when the window has come to rest: no move or resize for a moment
    /// and the mouse button is up.
    var onSettle: ((Target) -> Void)?
    /// Bundle ids that count as browsers.
    var browserBundleIds: Set<String>

    private(set) var target: Target?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var observedWindow: AXUIElement?
    private var appElement: AXUIElement?
    private var workspaceToken: NSObjectProtocol?
    private var displayLink: CADisplayLink?
    private var mouseMonitor: Any?
    private var settleWork: DispatchWorkItem?
    /// The bound window's window-server number, for frame reads during a drag.
    private var windowNumber: CGWindowID?

    init(browserBundleIds: Set<String>) {
        self.browserBundleIds = browserBundleIds
        super.init()
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to the Accessibility pane.
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func start() {
        guard workspaceToken == nil else { return }
        workspaceToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.frontAppChanged(app) }
        }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseEvent(e.type) }
        }
        frontAppChanged(NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        if let m = mouseMonitor { NSEvent.removeMonitor(m) }
        mouseMonitor = nil
        if let t = workspaceToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        workspaceToken = nil
        detach()
        publish(nil)
    }

    /// The window the sidebar is bound to, to resize it again later (for
    /// example to give it its space back when the sidebar is turned off).
    var boundWindow: AXUIElement? { observedWindow }

    /// A window's frame now, in Cocoa coordinates.
    func currentFrame(of win: AXUIElement) -> CGRect? { frame(of: win) }

    /// Moves/resizes a browser window, the bound one by default. Cocoa coordinates.
    func setWindowFrame(_ frame: CGRect, of window: AXUIElement? = nil) {
        guard let win = window ?? observedWindow, let h = NSScreen.screens.first?.frame.height else { return }
        let ax = SidebarGeometry.ax(fromCocoa: frame, mainScreenHeight: h)
        var origin = ax.origin, size = ax.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        // Size, position, size: macOS limits each step to what fits on screen
        // at that moment, so a move that needs the new size comes after it.
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
        AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p)
        AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s)
        if window == nil || CFEqual(win, observedWindow as CFTypeRef?) { refresh() }
    }

    /// Brings the browser back to the front (after a click in the sidebar).
    func activateBrowser() {
        guard let t = target else { return }
        NSRunningApplication(processIdentifier: t.pid)?.activate()
    }

    // MARK: - Front app

    private func frontAppChanged(_ app: NSRunningApplication?) {
        guard let app else { return }
        // Our own panel or window coming forward must not unbind the sidebar.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        guard let id = app.bundleIdentifier, browserBundleIds.contains(id) else {
            detach()
            publish(nil)
            return
        }
        if app.processIdentifier != observedPid { attach(app) }
        refresh()
    }

    private func attach(_ app: NSRunningApplication) {
        detach()
        let pid = app.processIdentifier
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { tracker.axEvent(name, element: element) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let appEl = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXWindowMovedNotification, kAXWindowResizedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                  kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(obs, appEl, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        observedPid = pid
        appElement = appEl
    }

    private func detach() {
        stopDragTracking()
        settleWork?.cancel()
        windowNumber = nil
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedPid = 0
        observedWindow = nil
        appElement = nil
    }

    // MARK: - AX events

    private func axEvent(_ name: String, element: AXUIElement) {
        switch name {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            refresh()
        case kAXWindowMovedNotification, kAXWindowResizedNotification, kAXMovedNotification, kAXResizedNotification:
            if displayLink != nil { return } // the drag is already being followed
            refresh()
            scheduleSettle()
        default:
            refresh()
        }
    }

    /// Re-reads the focused window and its frame, and publishes if anything changed.
    func refresh() {
        guard let appEl = appElement, let app = NSRunningApplication(processIdentifier: observedPid) else {
            publish(nil); return
        }
        if app.isHidden { publish(nil); return }
        guard let win = browserWindow(of: appEl), let frame = frame(of: win) else { publish(nil); return }
        if observedWindow.map({ !CFEqual($0, win) }) ?? true { watchWindow(win) }
        if windowNumber == nil { windowNumber = findWindowNumber(frame) }
        let fullScreen: Bool = copy(win, "AXFullScreen") ?? false
        publish(Target(pid: observedPid, bundleId: app.bundleIdentifier ?? "",
                       appName: app.localizedName ?? "Browser",
                       title: copy(win, kAXTitleAttribute) ?? "",
                       frame: frame, fullScreen: fullScreen, windowHash: Int(CFHash(win))))
    }

    /// The window to bind to: the focused one when it is a main browser window.
    /// A save panel, an extension's popup, a menu or a dialog takes the focus
    /// without being one; then the sidebar stays on the window it is on.
    private func browserWindow(of app: AXUIElement) -> AXUIElement? {
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w: AXUIElement = copy(app, attr), isMainWindow(w) {
                return isMinimized(w) ? nil : w
            }
        }
        let all: [AXUIElement] = copy(app, kAXWindowsAttribute) ?? []
        if let old = observedWindow, all.contains(where: { CFEqual($0, old) }), !isMinimized(old) { return old }
        return all.first { isMainWindow($0) && !isMinimized($0) }
    }

    private func isMainWindow(_ w: AXUIElement) -> Bool {
        let role: String? = copy(w, kAXRoleAttribute), subrole: String? = copy(w, kAXSubroleAttribute)
        guard role == (kAXWindowRole as String), subrole == (kAXStandardWindowSubrole as String) else { return false }
        let minimize: AXUIElement? = copy(w, kAXMinimizeButtonAttribute)
        let fullScreen: AXUIElement? = copy(w, kAXFullScreenButtonAttribute)
        return minimize != nil && fullScreen != nil
    }

    private func isMinimized(_ w: AXUIElement) -> Bool { copy(w, kAXMinimizedAttribute) ?? false }

    // MARK: - Window server frames

    private static func axBounds(_ info: [String: Any]) -> CGRect? {
        (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
    }

    private func findWindowNumber(_ cocoa: CGRect) -> CGWindowID? {
        guard let h = NSScreen.screens.first?.frame.height,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let want = SidebarGeometry.ax(fromCocoa: cocoa, mainScreenHeight: h)
        let hit = list.first { i in
            guard i[kCGWindowOwnerPID as String] as? pid_t == observedPid, i[kCGWindowLayer as String] as? Int == 0,
                  let b = Self.axBounds(i) else { return false }
            return abs(b.minX - want.minX) < 2 && abs(b.minY - want.minY) < 2
                && abs(b.width - want.width) < 2 && abs(b.height - want.height) < 2
        }
        return (hit?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    /// Reads the frame from the window server. True when it changed.
    @discardableResult
    private func fastRefresh() -> Bool {
        guard var t = target, let n = windowNumber, let h = NSScreen.screens.first?.frame.height,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], n) as? [[String: Any]])?.first,
              let b = Self.axBounds(info) else { return false }
        t.frame = SidebarGeometry.cocoa(fromAX: b, mainScreenHeight: h)
        guard t != target else { return false }
        publish(t)
        return true
    }

    private func mouseEvent(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDragged:
            if displayLink == nil, fastRefresh() { startDragTracking() }
        default:
            let wasDragging = displayLink != nil
            stopDragTracking()
            if wasDragging { refresh() }
            if target != nil { scheduleSettle() }
        }
    }

    private func scheduleSettle() {
        settleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return } // mouse up schedules again
                self.refresh()
                if let t = self.target { self.onSettle?(t) }
            }
        }
        settleWork = work
        // Long enough for an animated snap (macOS tiling) to finish moving.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func watchWindow(_ win: AXUIElement) {
        if let obs = observer, let old = observedWindow {
            for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                AXObserverRemoveNotification(obs, old, n as CFString)
            }
        }
        observedWindow = win
        windowNumber = nil
        scheduleSettle()
        guard let obs = observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(obs, win, n as CFString, refcon)
        }
    }

    private func frame(of win: AXUIElement) -> CGRect? {
        guard let pv: AXValue = copy(win, kAXPositionAttribute), let sv: AXValue = copy(win, kAXSizeAttribute),
              let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return SidebarGeometry.cocoa(fromAX: CGRect(origin: p, size: s), mainScreenHeight: mainHeight)
    }

    private func publish(_ t: Target?) {
        guard t != target else { return }
        target = t
        onChange?(t)
    }

    // MARK: - Live drag

    private func startDragTracking() {
        guard displayLink == nil, let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(dragTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDragTracking() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func dragTick() {
        fastRefresh()
        // Normally the mouse-up event ends the drag; this covers a missed one.
        if NSEvent.pressedMouseButtons & 1 == 0 { mouseEvent(.leftMouseUp) }
    }

    // MARK: - AX helpers

    private func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }
}
