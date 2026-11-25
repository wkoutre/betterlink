import AppKit
import ApplicationServices

/// One browser main window being followed.
@MainActor
final class TrackedWindow {
    /// Its identity while it exists, never reused.
    let id: Int
    let element: AXUIElement
    /// Its window-server number.
    let number: CGWindowID
    /// Nil once its browser is no longer followed.
    private(set) weak var watcher: BrowserWatcher?
    var target: WindowTracker.Target
    var settleWork: DispatchWorkItem?

    private static var lastId = 0

    init(element: AXUIElement, number: CGWindowID, watcher: BrowserWatcher) {
        Self.lastId += 1
        id = Self.lastId
        self.element = element
        self.number = number
        self.watcher = watcher
        target = .init(id: id, pid: watcher.pid, bundleId: watcher.bundleId, appName: watcher.name,
                       title: "", frame: .zero, fullScreen: false, minimized: false, appHidden: false)
    }

    /// Reads the window again. False when it can't be read now.
    @discardableResult
    func read() -> Bool {
        guard let frame = AXWindow.frame(of: element) else { return false }
        target.frame = frame
        target.title = AXWindow.copy(element, kAXTitleAttribute) ?? ""
        target.fullScreen = AXWindow.copy(element, "AXFullScreen") ?? false
        target.minimized = AXWindow.copy(element, kAXMinimizedAttribute) ?? false
        target.appHidden = watcher?.isHidden ?? false
        return true
    }

    /// Whether it is its browser's focused main window.
    var isFocused: Bool { watcher?.focused === self }
}

/// Watches one running browser's main windows through one AXObserver: windows
/// coming and going, focused, moved, resized, minimized, renamed, hidden.
@MainActor
final class BrowserWatcher {
    let pid: pid_t
    let bundleId: String
    let name: String
    private let app: NSRunningApplication
    private let element: AXUIElement
    private unowned let tracker: WindowTracker
    private var observer: AXObserver?
    private var triesLeft = 5

    private(set) var windows: [TrackedWindow] = []
    /// The browser's focused main window, whether or not it is in front.
    private(set) var focused: TrackedWindow?

    var isHidden: Bool { app.isHidden }

    init(_ app: NSRunningApplication, tracker: WindowTracker) {
        self.app = app
        self.tracker = tracker
        pid = app.processIdentifier
        bundleId = app.bundleIdentifier ?? ""
        name = app.localizedName ?? "Browser"
        element = AXUIElementCreateApplication(pid)
        // A hung browser in the background must not hold everything up.
        AXUIElementSetMessagingTimeout(element, 1)
    }

    /// Starts watching, again when an earlier try failed: a browser that has
    /// only just launched may not answer yet, so a failed try is repeated a few
    /// times (and when the browser next comes to the front).
    func start() {
        guard observer == nil else { return }
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<BrowserWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { watcher.event(name, element) }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
                  kAXWindowMovedNotification, kAXWindowResizedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                  kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            let answer = AXObserverAddNotification(obs, element, n as CFString, refcon)
            guard answer == .cannotComplete else { continue }
            if triesLeft > 0 {
                triesLeft -= 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startIfWatched() }
            }
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
        scan()
    }

    private var stopped = false
    private func startIfWatched() { if !stopped { start() } }

    func stop() {
        stopped = true
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        focused = nil
        for w in windows { w.settleWork?.cancel() }
        windows = []
    }

    // MARK: - Windows

    /// Finds the main windows not followed yet. Accessibility lists only those
    /// on a Space that is showing, so a window missing from the list isn't gone.
    func scan() {
        guard observer != nil else { return }
        for w in AXWindow.copy(element, kAXWindowsAttribute) as [AXUIElement]? ?? [] { follow(w) }
        updateFocus()
    }

    /// Lets go of windows the window server no longer has.
    func drop(missingFrom all: Set<UInt32>) {
        for w in windows where !all.contains(w.number) { remove(w) }
    }

    func refresh() { for w in windows { refresh(w) } }

    /// Reads a window again, and reports it if anything changed.
    func refresh(_ w: TrackedWindow) {
        let old = w.target
        if w.read(), w.target != old { tracker.onChange?(w.target) }
    }

    @discardableResult
    private func follow(_ win: AXUIElement) -> TrackedWindow? {
        if let known = tracked(win) { return known }
        guard AXWindow.isMain(win), let number = AXWindow.number(of: win) else { return nil }
        let w = TrackedWindow(element: win, number: number, watcher: self)
        guard w.read() else { return nil }
        windows.append(w)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification, kAXUIElementDestroyedNotification] {
            if let obs = observer { AXObserverAddNotification(obs, win, n as CFString, refcon) }
        }
        tracker.onAdded?(w)
        tracker.scheduleSettle(w)
        return w
    }

    private func remove(_ w: TrackedWindow) {
        w.settleWork?.cancel()
        windows.removeAll { $0 === w }
        if focused === w { focused = nil }
        tracker.removed(w)
    }

    private func tracked(_ win: AXUIElement) -> TrackedWindow? { windows.first { CFEqual($0.element, win) } }

    private func updateFocus() {
        var now: TrackedWindow?
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] where now == nil {
            now = (AXWindow.copy(element, attr) as AXUIElement?).flatMap(follow)
        }
        // A popup or panel can have the focus with no main window reported:
        // the last one keeps it.
        guard let now, now !== focused else { return }
        focused = now
        tracker.focusChanged()
    }

    /// Whether `w` is the browser's focused, main window: the one its menu
    /// commands act on.
    func isFocusedMain(_ w: TrackedWindow) -> Bool {
        guard let f: AXUIElement = AXWindow.copy(element, kAXFocusedWindowAttribute) else { return false }
        return CFEqual(f, w.element) && (AXWindow.copy(w.element, kAXMainAttribute) as Bool?) == true
    }

    /// Brings the window, and with it the browser, to the front.
    func activate(_ w: TrackedWindow) {
        if !isFocusedMain(w) { AXWindow.raise(w.element) }
        app.activate()
    }

    // MARK: - Events

    private func event(_ name: String, _ el: AXUIElement) {
        switch name {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            updateFocus()
            tracker.orderMayHaveChanged()
        case kAXWindowCreatedNotification:
            scan()
            // A window is often announced before it has its title bar's buttons.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scan() }
        case kAXUIElementDestroyedNotification:
            if let w = tracked(el) { remove(w) }
        case kAXApplicationHiddenNotification, kAXApplicationShownNotification:
            refresh()
            // A window first seen while its browser was hidden settles now.
            if name == kAXApplicationShownNotification { windows.forEach(tracker.scheduleSettle) }
            tracker.orderMayHaveChanged()
        case kAXTitleChangedNotification:
            guard let w = tracked(el) else { return }
            let title: String = AXWindow.copy(el, kAXTitleAttribute) ?? ""
            guard title != w.target.title else { return }
            w.target.title = title
            tracker.onChange?(w.target)
        default: // moved, resized, minimized, back from the Dock
            guard let w = tracked(el), !tracker.isDragging(w) else { return }
            refresh(w)
            tracker.scheduleSettle(w)
        }
    }
}
