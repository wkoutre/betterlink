import AppKit
import ApplicationServices
import BetterlinkCore

/// One browser window being followed.
@MainActor
final class TrackedWindow {
    /// Its identity while it exists, never reused.
    let id: Int
    let element: AXUIElement
    /// Its window-server number.
    let number: CGWindowID
    /// What reads and moves it (Accessibility; a fake browser in tests).
    let handle: WindowHandle
    /// Nil once its browser is no longer followed.
    private(set) weak var watcher: BrowserWatcher?
    var target: WindowTracker.Target
    var settleWork: DispatchWorkItem?
    /// Followed for its title and place only, with no sidebar yet: whether it
    /// is a browser window is for the browser to say, through the pairing
    /// (`BrowserWatcher.said`).
    fileprivate(set) var awaitsWord = false

    private static var lastId = 0

    init(element: AXUIElement, number: CGWindowID, watcher: BrowserWatcher, handle: WindowHandle? = nil) {
        Self.lastId += 1
        id = Self.lastId
        self.element = element
        self.number = number
        self.handle = handle ?? AXHandle(element: element, number: number)
        self.watcher = watcher
        target = .init(id: id, pid: watcher.pid, bundleId: watcher.bundleId, appName: watcher.name,
                       title: "", frame: .zero, fullScreen: false, minimized: false, appHidden: false)
    }

    /// Reads the window again. False when it can't be read now.
    @discardableResult
    func read() -> Bool {
        guard let frame = AXWindow.frame(of: handle) else { return false }
        target.frame = frame
        target.title = AXWindow.copy(element, kAXTitleAttribute) ?? ""
        target.fullScreen = AXWindow.copy(element, "AXFullScreen") ?? false
        target.minimized = AXWindow.copy(element, kAXMinimizedAttribute) ?? false
        target.appHidden = watcher?.isHidden ?? false
        return true
    }

    /// Whether it has its browser's focus now, for the pairing.
    var isFocused: Bool { watcher?.hasFocus === self }
}

/// Watches one running browser's windows through one AXObserver: windows
/// coming and going, focused, moved, resized, minimized, renamed, hidden. Only
/// its browser windows are followed, the ones with tabs (`WindowKinds`): an
/// extension's palette, an app window or DevTools on its own is not.
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
    /// What each of the browser's standard windows has been seen to be, by
    /// window number.
    private var kinds = WindowKinds()
    /// The next look at each window not known yet, by window number.
    private var looks: [CGWindowID: DispatchWorkItem] = [:]
    /// The window with a sidebar that last had the browser's focus, whether
    /// or not the browser is in front.
    private(set) var focused: TrackedWindow?
    /// The followed window that has the browser's focus now: nil while a
    /// standard window that isn't followed has it (a palette, an app window).
    /// The browser then says its popup has the focus, and the window that
    /// last had it must not pass for the one meant.
    private(set) var hasFocus: TrackedWindow?
    /// The windows awaiting the browser's word, by window number: since when,
    /// and the end of the wait.
    private var awaited: [CGWindowID: (since: CFTimeInterval, end: DispatchWorkItem)] = [:]
    /// Whether `act` is to run once the pairing that spoke is done.
    private var acting = false

    var isHidden: Bool { app.isHidden }

    init(_ app: NSRunningApplication, tracker: WindowTracker) {
        self.app = app
        self.tracker = tracker
        pid = app.processIdentifier
        bundleId = app.bundleIdentifier ?? ""
        name = app.localizedName ?? "Browser"
        element = AXUIElementCreateApplication(pid)
        // A hung browser in the background must not hold everything up.
        AXWindow.limitWaiting(on: element)
    }

    /// The browser did not answer in time. Until it is heard from again (any
    /// event), it is not asked on Space and display changes: each call would
    /// wait out its time on the main thread.
    private(set) var isStalled = false

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
        hasFocus = nil
        for w in windows { w.settleWork?.cancel() }
        windows = []
        looks.values.forEach { $0.cancel() }
        looks = [:]
        awaited.values.forEach { $0.end.cancel() }
        awaited = [:]
    }

    // MARK: - Windows

    /// Finds the browser windows not followed yet. Accessibility lists only
    /// those on a Space that is showing, so a window missing from the list
    /// isn't gone.
    func scan() {
        guard observer != nil else { return }
        guard let all: [AXUIElement] = AXWindow.copy(element, kAXWindowsAttribute) else {
            if AXWindow.timedOut { isStalled = true }
            return
        }
        consider(all, changed: false)
        updateFocus()
    }

    /// Lets go of windows the window server no longer has.
    func drop(missingFrom all: Set<UInt32>) {
        for w in windows where !all.contains(w.number) { remove(w) }
        forget(missingFrom: all)
    }

    /// Forgets what was known of windows the window server no longer has,
    /// and the looks still to come at them. The followed ones are let go by
    /// `remove`; this is for a window that was judged and never followed.
    func forget(missingFrom all: Set<UInt32>) {
        kinds.keep(all)
        for (n, look) in looks where !all.contains(n) {
            look.cancel()
            looks[n] = nil
        }
    }

    /// Lets go of followed windows that turned out not to be browser windows:
    /// followed while nothing could tell, and since then called a popup or an
    /// app window by the browser, or never seen with tabs once the browser
    /// showed some. Called on the settled pass, never mid-event. They are
    /// still open, so each gets its space back.
    func dropNotBrowser() {
        for w in windows where kinds.kind(of: w.number) == .notBrowser {
            DragTrace.log("kinds: \(bundleId) window \(w.number) is not a browser window after all: let go")
            letGo(w)
        }
    }

    /// Stops following a window that is still open.
    private func letGo(_ w: TrackedWindow) {
        for n in Self.windowEvents { if let obs = observer { AXObserverRemoveNotification(obs, w.element, n as CFString) } }
        remove(w, closed: false)
    }

    // MARK: - The browser's own word

    /// The browser's own word for this browser's windows, as the pairing has
    /// it now: what the extension calls the browser window each is paired
    /// with. `listening`: the extension is connected for this browser, so a
    /// word can come. Acted on after the pairing that says it is done.
    func said(_ words: [CGWindowID: WindowKinds.Word], listening: Bool) {
        let was = kinds
        kinds.listening = listening
        kinds.said(words)
        guard kinds != was else { return }
        for (n, word) in words {
            guard let wait = awaited.removeValue(forKey: n) else { continue }
            wait.end.cancel()
            DragTrace.log(String(format: "kinds: %@ window %u waited %.0f ms for its word: %@", bundleId, n,
                                 (CACurrentMediaTime() - wait.since) * 1000, word == .normal ? "normal" : "not normal"))
        }
        guard !acting else { return }
        acting = true
        DispatchQueue.main.async { [weak self] in
            self?.acting = false
            self?.act()
        }
    }

    /// Acts on what each followed window is now known to be.
    private func act() {
        guard observer != nil else { return }
        for w in windows { judge(w.element, w.number) }
    }

    /// A window only the browser's word can tell is followed without a
    /// sidebar, and waits for that word no longer than `WindowKinds.wordWait`.
    private func awaitWord(for w: TrackedWindow) {
        let n = w.number
        let end = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let wait = self.awaited.removeValue(forKey: n) else { return }
                self.kinds.waited(n)
                DragTrace.log(String(format: "kinds: %@ window %u waited %.0f ms for its word: none came", self.bundleId, n,
                                     (CACurrentMediaTime() - wait.since) * 1000))
                self.act()
            }
        }
        awaited[n] = (CACurrentMediaTime(), end)
        DispatchQueue.main.asyncAfter(deadline: .now() + WindowKinds.wordWait, execute: end)
    }

    /// A window followed without a sidebar is a browser window: it gets one.
    private func show(_ w: TrackedWindow) {
        guard w.awaitsWord else { return }
        w.awaitsWord = false
        awaited.removeValue(forKey: w.number)?.end.cancel()
        if hasFocus === w { focused = w }
        tracker.onKnown?(w)
        tracker.scheduleSettle(w)
    }

    /// Reads every window again, as far as the browser answers.
    func refresh() { for w in windows where !isStalled { refresh(w) } }

    /// Reads a window again, and reports it if anything changed.
    func refresh(_ w: TrackedWindow) {
        let old = w.target
        guard w.read() else {
            if AXWindow.timedOut { isStalled = true }
            return
        }
        if w.target != old { tracker.onChange?(w.target) }
    }

    /// Looks at the standard windows among `wins` that are not followed, and
    /// follows the browser windows. All are read before any is judged: a
    /// palette read before the normal window beside it would get a sidebar
    /// for want of knowing that this browser shows its tabs.
    ///
    /// A window already judged not to be a browser window is not read again
    /// for being listed or focused (a palette left open would be walked on
    /// every switch between windows). `changed`: the event is one that can
    /// change what these very windows show, so they get their looks afresh.
    private func consider(_ wins: [AXUIElement], changed: Bool) {
        var found: [(win: AXUIElement, number: CGWindowID)] = []
        var read: [CGWindowID: WindowKinds.Reading] = [:]
        for win in wins where tracked(win) == nil {
            // A browser that has stopped answering is not asked about the rest.
            guard !isStalled else { break }
            AXWindow.limitWaiting(on: win) // kept as the window's element
            // One with a look to come is left to it.
            guard let n = AXWindow.number(of: win), looks[n] == nil, !found.contains(where: { $0.number == n }) else { continue }
            let look = changed || kinds.needsLook(n)
            guard look || kinds.kind(of: n) == .browser, AXWindow.isMain(win) else { continue }
            if kinds.isNew(n) { DragTrace.log("kinds: \(bundleId) window \(n) appeared") }
            if changed { kinds.startOver(n) }
            found.append((win, n))
            if look { read[n] = reading(win, n) }
        }
        guard !found.isEmpty else { return }
        // A browser not seen with tabs yet may show them by now in a window
        // followed while it was still opening: one is enough to know.
        if !kinds.readable, !read.values.contains(where: \.holdsTabs) {
            for w in windows {
                let r = reading(w.element, w.number)
                read[w.number] = r
                if r?.holdsTabs == true { break }
            }
        }
        take(read)
        for f in found { judge(f.win, f.number) }
    }

    /// One look at a window. Nil when it is gone, or its browser isn't answering.
    private func reading(_ win: AXUIElement, _ n: CGWindowID) -> WindowKinds.Reading? {
        guard !isStalled else { return nil }
        let r = AXWindow.tabs(in: win)
        if r == nil, AXWindow.timedOut { isStalled = true }
        let cost = AXWindow.lastWalk
        DragTrace.log(String(format: "kinds: %@ window %u walked: %d calls, %.1f ms%@", bundleId, n, cost.calls, cost.ms, r == nil ? ", not read" : ""))
        return r
    }

    /// Takes in what a look found. When it is the first to show this browser's
    /// tabs, the windows followed so far are judged by them too.
    private func take(_ read: [CGWindowID: WindowKinds.Reading]) {
        let was = kinds.readable
        kinds.saw(read)
        for (n, r) in read {
            DragTrace.log("kinds: \(bundleId) window \(n): tab groups \(r.tabGroups), tabs \(r.tabs): \(kinds.kind(of: n))")
        }
        if kinds.readable != was { act() }
    }

    /// Acts on what a window is now known to be. A browser window is followed
    /// and gets its sidebar. One that only the browser's word can tell is
    /// followed without one, so the pairing can give that word. One that is
    /// not a browser window is left alone: if it had a sidebar it goes on the
    /// settled pass, and if it was only awaiting its word it is let go at
    /// once. A window whose tabs haven't been seen gets its next look.
    private func judge(_ win: AXUIElement, _ n: CGWindowID) {
        let w = tracked(win)
        switch kinds.kind(of: n) {
        case .browser:
            if let w { show(w) } else { follow(win, number: n, awaitingWord: false) }
        case .unknown:
            if w == nil, kinds.awaitsWord(n) { follow(win, number: n, awaitingWord: true) }
        case .notBrowser:
            if let w { w.awaitsWord ? letGo(w) : tracker.orderMayHaveChanged() }
        }
        lookAgain(at: win, n)
    }

    /// One more look at a window whose tabs haven't been seen, after the wait
    /// `WindowKinds` gives it (none once it is known). A one-shot timer:
    /// nothing runs once every window is known.
    private func lookAgain(at win: AXUIElement, _ n: CGWindowID) {
        guard looks[n] == nil, let wait = kinds.wait(for: n) else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.observer != nil else { return }
                self.looks[n] = nil
                guard let r = self.reading(win, n) else {
                    // Closed meanwhile. (A browser that isn't answering is
                    // looked at again when it next sends an event.)
                    if !self.isStalled, self.tracked(win) == nil { self.kinds.forget(n) }
                    return
                }
                self.take([n: r])
                self.judge(win, n)
            }
        }
        looks[n] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    private static let windowEvents = [kAXMovedNotification, kAXResizedNotification, kAXTitleChangedNotification, kAXUIElementDestroyedNotification]

    private func follow(_ win: AXUIElement, number: CGWindowID, awaitingWord: Bool) {
        guard tracked(win) == nil else { return }
        let w = TrackedWindow(element: win, number: number, watcher: self)
        guard w.read() else { return }
        w.awaitsWord = awaitingWord
        windows.append(w)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in Self.windowEvents {
            if let obs = observer { AXObserverAddNotification(obs, win, n as CFString, refcon) }
        }
        if awaitingWord { awaitWord(for: w) }
        tracker.onAdded?(w)
        tracker.scheduleSettle(w)
    }

    /// `closed`: the window is gone (Accessibility said so, or the window
    /// server no longer has it), rather than only no longer followed. Once:
    /// a window let go already is left alone, whichever says it second.
    func remove(_ w: TrackedWindow, closed: Bool = true) {
        guard windows.contains(where: { $0 === w }) else { return }
        w.settleWork?.cancel()
        windows.removeAll { $0 === w }
        if focused === w { focused = nil }
        if hasFocus === w { hasFocus = nil }
        awaited.removeValue(forKey: w.number)?.end.cancel()
        if closed { kinds.forget(w.number) }
        tracker.removed(w, closed: closed)
    }

    private func tracked(_ win: AXUIElement) -> TrackedWindow? { windows.first { CFEqual($0.element, win) } }

    private func updateFocus() {
        var now: TrackedWindow?, elsewhere = false
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] where now == nil {
            guard let win: AXUIElement = AXWindow.copy(element, attr) else { continue }
            consider([win], changed: false)
            now = tracked(win)
            // A standard window that isn't followed: a palette, an app window.
            if now == nil, let n = AXWindow.number(of: win), !kinds.isNew(n) { elsewhere = true }
        }
        // A popup or panel can have the focus with no main window reported:
        // the last one keeps it. Not for the pairing while a standard window
        // that isn't followed has it.
        let has = now ?? (elsewhere ? nil : focused)
        let shown = now.flatMap { $0.awaitsWord ? nil : $0 }
        guard has !== hasFocus || (shown != nil && shown !== focused) else { return }
        hasFocus = has
        if let shown { focused = shown }
        DragTrace.log(has.map { "focus: macOS says window \($0.number) of \(bundleId) has it" }
                      ?? "focus: macOS says a window of \(bundleId) that isn't followed has it")
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
        // It speaks again: look for what was missed meanwhile.
        if isStalled { isStalled = false; scan() }
        switch name {
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            updateFocus()
            tracker.orderMayHaveChanged()
        case kAXWindowCreatedNotification:
            scan()
            // Followed or not (a window on another Space isn't): the browser has one more.
            tracker.focusChanged()
            // A window is often announced before it has its title bar's buttons.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.scan() }
        case kAXUIElementDestroyedNotification:
            // Only a followed window's is asked for. A browser can be late
            // with it (the window server's list is what says a window is
            // gone meanwhile), and if this isn't one known by that name, the
            // count finds which is gone.
            if let w = tracked(el) {
                DragTrace.log("closed: macOS says window \(w.number) of \(bundleId) is gone")
                remove(w)
            } else {
                DragTrace.log("closed: macOS says a window of \(bundleId) is gone, none followed by that name")
                tracker.focusChanged()
            }
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
            guard let w = tracked(el) else {
                // A window judged not to be a browser window may show its tabs
                // now: it is back from the Dock, or was resized (leaving full
                // screen is a resize). A move changes nothing it shows.
                if name == kAXWindowDeminiaturizedNotification || name == kAXWindowResizedNotification,
                   let n = AXWindow.number(of: el), looks[n] == nil, kinds.kind(of: n) == .notBrowser {
                    consider([el], changed: true)
                }
                return
            }
            guard !tracker.isDragging(w) else { return }
            refresh(w)
            tracker.scheduleSettle(w)
        }
    }
}
