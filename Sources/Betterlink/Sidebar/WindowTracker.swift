import AppKit
import ApplicationServices
import BetterlinkCore
import TabSyncCore

/// Follows every browser window of every running attached browser (which of
/// a browser's windows those are: BrowserWatcher), in front or not: which
/// there are, and each one's frame, title and state, the moment they change.
/// Event-driven throughout:
///
/// - NSWorkspace tells us when apps launch, quit or come to the front, and when
///   another Space shows.
/// - An AXObserver on each browser (BrowserWatcher) tells us about its windows.
/// - During a live drag the frame comes from the window server, not from the
///   browser (an Accessibility read waits for the browser's busy main thread):
///   on every mouse-drag event, and once per display refresh until mouse up.
///
/// Needs the Accessibility permission (System Settings › Privacy & Security ›
/// Accessibility). Without it, `isTrusted` is false and nothing is reported.
@MainActor
final class WindowTracker: NSObject {
    struct Target: Equatable {
        /// Identity of the window, to tell "same window moved" from "another window".
        var id: Int
        var pid: pid_t
        var bundleId: String
        var appName: String
        /// The window's title (Chromium: the active tab's title).
        var title: String
        /// Cocoa global coordinates.
        var frame: CGRect
        var fullScreen: Bool
        var minimized: Bool
        var appHidden: Bool
    }

    /// A window is followed: with a sidebar to come, or (`awaitsWord`) only
    /// for its title and place until the browser's word says what it is.
    var onAdded: ((TrackedWindow) -> Void)?
    /// A window followed without a sidebar is a browser window after all.
    var onKnown: ((TrackedWindow) -> Void)?
    /// `closed`: the window is gone, rather than no longer followed.
    var onRemoved: ((TrackedWindow, _ closed: Bool) -> Void)?
    var onChange: ((Target) -> Void)?
    /// A window has come to rest: no move or resize for a moment and the mouse
    /// button is up.
    var onSettle: ((Target) -> Void)?
    /// Another window has the focus, in its browser or of all, or a browser
    /// has made or lost a window (followed or not).
    var onFocus: (() -> Void)?
    /// What is on screen, or in which order, may have changed. `settled`: a
    /// moment later, when Spaces and windows have stopped moving.
    var onScreen: ((_ settled: Bool) -> Void)?
    /// The number of the panel beside window `id`, for DragTrace (diagnostics only).
    var onDragStart: ((_ id: Int) -> Int?)?

    /// Bundle ids that count as browsers.
    var browserBundleIds: Set<String> {
        didSet { if isRunning { watchRunning() } }
    }

    private var watchers: [pid_t: BrowserWatcher] = [:]
    /// Every window followed now.
    var windows: [TrackedWindow] { watchers.values.flatMap(\.windows) }
    private var tokens: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var isRunning: Bool { !tokens.isEmpty }
    private var mouseMonitor: Any?
    private var drag: (window: TrackedWindow, link: CADisplayLink)?
    private var settledWork: DispatchWorkItem?
    /// Windows that moved while the mouse was down: settled when it comes up.
    private var waitingForMouseUp: [TrackedWindow] = []

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
        guard !isRunning else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        listen(workspace, NSWorkspace.didActivateApplicationNotification) { t, _ in t.frontAppChanged() }
        // Only a browser's coming or going: other apps launch and quit all day.
        listen(workspace, NSWorkspace.didLaunchApplicationNotification) { t, app in
            if let id = app?.bundleIdentifier, t.browserBundleIds.contains(id) { t.watchRunning() }
        }
        listen(workspace, NSWorkspace.didTerminateApplicationNotification) { t, app in
            if let pid = app?.processIdentifier, t.watchers[pid] != nil { t.watchRunning() }
        }
        listen(workspace, NSWorkspace.activeSpaceDidChangeNotification) { t, _ in
            guard !t.watchers.isEmpty else { return }
            let all = WindowServer.all()
            for w in t.watchers.values {
                w.drop(missingFrom: all)
                if !w.isStalled { w.scan() } // the windows of the Space that shows now
            }
            t.orderMayHaveChanged()
        }
        listen(.default, NSApplication.didChangeScreenParametersNotification) { t, _ in
            t.watchers.values.forEach { $0.refresh() } // not a browser that isn't answering
            t.orderMayHaveChanged()
        }
        watchRunning()
        frontAppChanged()
    }

    private func listen(_ center: NotificationCenter, _ name: Notification.Name,
                        _ body: @escaping @MainActor (WindowTracker, NSRunningApplication?) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { if let self { body(self, app) } }
        }
        tokens.append((center, token))
    }

    func stop() {
        for t in tokens { t.center.removeObserver(t.token) }
        tokens = []
        settledWork?.cancel()
        for pid in Array(watchers.keys) { unwatch(pid, closed: false) }
        waitingForMouseUp = []
        updateMouseMonitor()
    }

    // MARK: - Browsers

    /// Follows each attached browser that is running, and lets go of the rest.
    private func watchRunning() {
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let pids = Set(running.map(\.processIdentifier))
        for (pid, w) in watchers where !pids.contains(pid) || !browserBundleIds.contains(w.bundleId) {
            unwatch(pid, closed: !pids.contains(pid))
        }
        for app in running {
            guard let id = app.bundleIdentifier, browserBundleIds.contains(id), watchers[app.processIdentifier] == nil else { continue }
            let w = BrowserWatcher(app, tracker: self)
            watchers[app.processIdentifier] = w
            w.start()
        }
        updateMouseMonitor()
        orderMayHaveChanged()
    }

    private func unwatch(_ pid: pid_t, closed: Bool) {
        guard let w = watchers.removeValue(forKey: pid) else { return }
        let windows = w.windows
        if let d = drag, d.window.watcher === w { stopDrag() }
        waitingForMouseUp.removeAll { $0.watcher === w }
        w.stop()
        for window in windows { onRemoved?(window, closed) }
        updateMouseMonitor()
    }

    private var frontWatcher: BrowserWatcher? {
        (NSWorkspace.shared.frontmostApplication?.processIdentifier).flatMap { watchers[$0] }
    }

    /// Whether an attached browser is the front app.
    var browserInFront: Bool { frontWatcher != nil }

    /// The focused window of the attached browser in front, if one is.
    var frontWindow: TrackedWindow? { frontWatcher?.focused }

    private func frontAppChanged() {
        if let d = drag { endDrag(d.window) }
        frontWatcher?.start()
        updateMouseMonitor()
        onFocus?()
        orderMayHaveChanged()
    }

    func focusChanged() { onFocus?() }

    /// Hands every browser the pairing's word for its windows, by process and
    /// window number, and whether the extension is connected for it.
    func said(_ words: [pid_t: [CGWindowID: WindowKinds.Word]], listening: (BrowserWatcher) -> Bool) {
        for w in watchers.values { w.said(words[w.pid] ?? [:], listening: listening(w)) }
    }

    /// The window server no longer has `w`: it is closed, whether or not
    /// Accessibility has said so yet.
    func closed(_ w: TrackedWindow) {
        if let watcher = w.watcher { watcher.remove(w) } else { removed(w, closed: true) }
    }

    /// The window server's list of the processes `pids`: what was known of
    /// their windows that are no longer in it is forgotten. A window that was
    /// judged and never followed says nothing when it closes.
    func forget(missingFrom alive: Set<UInt32>, of pids: Set<pid_t>) {
        for w in watchers.values where pids.contains(w.pid) { w.forget(missingFrom: alive) }
    }

    /// `closed`: the window is gone, rather than no longer followed.
    func removed(_ w: TrackedWindow, closed: Bool) {
        if drag?.window === w { stopDrag() }
        waitingForMouseUp.removeAll { $0 === w }
        onRemoved?(w, closed)
    }

    /// Reported at once, and again when windows and Spaces have stopped moving
    /// (a Dock click raises an app's windows after it says the app is in front).
    func orderMayHaveChanged() {
        onScreen?(false)
        settledWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A window seen not to be a browser window after all goes now,
                // with everything at rest.
                self.watchers.values.forEach { $0.dropNotBrowser() }
                self.onScreen?(true)
            }
        }
        settledWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Windows

    func scheduleSettle(_ w: TrackedWindow) {
        w.settleWork?.cancel()
        let work = DispatchWorkItem { [weak self, weak w] in
            MainActor.assumeIsolated {
                guard let self, let w, let watcher = w.watcher else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    // Mouse up settles it: the mouse is watched until then.
                    if !self.waitingForMouseUp.contains(where: { $0 === w }) { self.waitingForMouseUp.append(w) }
                    self.updateMouseMonitor()
                    return
                }
                watcher.refresh(w)
                self.onSettle?(w.target)
            }
        }
        w.settleWork = work
        // Long enough for an animated snap (macOS tiling) to finish moving.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: - Live drag

    /// Only while a browser is in front (a drag in any other app isn't ours),
    /// or a window that moved waits for the mouse to come up.
    private func updateMouseMonitor() {
        let wanted = isRunning && (frontWatcher != nil || !waitingForMouseUp.isEmpty)
        if wanted, mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] e in
                MainActor.assumeIsolated { self?.mouseEvent(e.type) }
            }
        } else if !wanted, let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
    }

    private func settleWaiting() {
        let waiting = waitingForMouseUp
        waitingForMouseUp = []
        waiting.forEach(scheduleSettle)
    }

    func isDragging(_ w: TrackedWindow) -> Bool { drag?.window === w }

    private func mouseEvent(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDragged:
            if drag == nil, let w = frontWindow, fastRefresh(w) {
                startDrag(w)
                if let panel = onDragStart?(w.id) { DragTrace.begin(browser: w.number, panel: panel) }
            }
        default:
            if let d = drag { endDrag(d.window) } else if let w = frontWindow { scheduleSettle(w) }
            settleWaiting()
            updateMouseMonitor()
        }
    }

    /// Reads the frame from the window server. True when it changed.
    @discardableResult
    private func fastRefresh(_ w: TrackedWindow) -> Bool {
        guard let frame = WindowServer.frame(w.number), frame != w.target.frame else { return false }
        w.target.frame = frame
        onChange?(w.target)
        return true
    }

    private func startDrag(_ w: TrackedWindow) {
        guard let screen = NSScreen.main else { return }
        let link = screen.displayLink(target: self, selector: #selector(dragTick))
        link.add(to: .main, forMode: .common)
        drag = (w, link)
    }

    private func stopDrag() {
        drag?.link.invalidate()
        drag = nil
    }

    private func endDrag(_ w: TrackedWindow) {
        DragTrace.end()
        stopDrag()
        w.watcher?.refresh(w)
        scheduleSettle(w)
    }

    @objc private func dragTick() {
        guard let w = drag?.window else { return }
        fastRefresh(w)
        // Normally the mouse-up event ends the drag; this covers a missed one.
        if NSEvent.pressedMouseButtons & 1 == 0 { mouseEvent(.leftMouseUp) }
    }
}
