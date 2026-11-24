import AppKit
import ApplicationServices
import BetterlinkCore

/// Follows the frontmost browser window: which one it is, and its frame, the
/// moment either changes. Event-driven throughout:
///
/// - NSWorkspace tells us when another app comes to the front.
/// - An AXObserver on that app tells us when its focused window changes, moves,
///   resizes, minimises or goes full screen.
/// - Only while the mouse button is held after a move/resize (a live drag) do
///   we also read the frame once per display refresh, so the sidebar tracks
///   the window frame-for-frame; the display link stops on mouse up.
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
    /// Bundle ids that count as browsers.
    var browserBundleIds: Set<String>

    private(set) var target: Target?
    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var observedWindow: AXUIElement?
    private var appElement: AXUIElement?
    private var workspaceToken: NSObjectProtocol?
    private var displayLink: CADisplayLink?

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
        frontAppChanged(NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        if let t = workspaceToken { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        workspaceToken = nil
        detach()
        publish(nil)
    }

    /// Moves/resizes the browser window (for "make room"). Cocoa coordinates.
    func setWindowFrame(_ frame: CGRect) {
        guard let win = observedWindow, let h = NSScreen.screens.first?.frame.height else { return }
        let ax = SidebarGeometry.ax(fromCocoa: frame, mainScreenHeight: h)
        var origin = ax.origin, size = ax.size
        if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, p) }
        if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, s) }
        refresh()
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
            refresh()
            // A live drag or resize: follow it frame by frame until the mouse is released.
            if NSEvent.pressedMouseButtons & 1 != 0 { startDragTracking() }
        case kAXUIElementDestroyedNotification:
            refresh()
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
        guard let win: AXUIElement = copy(appEl, kAXFocusedWindowAttribute) ?? copy(appEl, kAXMainWindowAttribute) else {
            publish(nil); return
        }
        if observedWindow.map({ CFHash($0) != CFHash(win) }) ?? true { watchWindow(win) }
        let subrole: String? = copy(win, kAXSubroleAttribute)
        let minimized: Bool = copy(win, kAXMinimizedAttribute) ?? false
        guard subrole == nil || subrole == (kAXStandardWindowSubrole as String), !minimized,
              let frame = frame(of: win) else { publish(nil); return }
        let fullScreen: Bool = copy(win, "AXFullScreen") ?? false
        publish(Target(pid: observedPid, bundleId: app.bundleIdentifier ?? "",
                       appName: app.localizedName ?? "Browser",
                       title: copy(win, kAXTitleAttribute) ?? "",
                       frame: frame, fullScreen: fullScreen, windowHash: Int(CFHash(win))))
    }

    private func watchWindow(_ win: AXUIElement) {
        if let obs = observer, let old = observedWindow {
            for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                AXObserverRemoveNotification(obs, old, n as CFString)
            }
        }
        observedWindow = win
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
        refresh()
        if NSEvent.pressedMouseButtons & 1 == 0 { stopDragTracking() }
    }

    // MARK: - AX helpers

    private func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        return v as? T
    }
}
