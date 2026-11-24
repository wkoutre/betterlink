import AppKit
import BetterlinkCore
import SwiftUI
import TabSyncCore

/// The betterlink sidebar: a panel that binds to the frontmost browser
/// window's left or right edge and moves with it, showing that window's tabs.
/// Settings live in UserDefaults (they describe this Mac's screen, not rules).
@MainActor
final class SidebarController: ObservableObject {
    static let shared = SidebarController()

    @Published var enabled: Bool { didSet { save(); enabled ? start() : stop() } }
    @Published var side: SidebarSide { didSet { save(); refit() } }
    @Published var width: Double { didSet { save(); refit() } }
    /// The browsers the sidebar attaches to, by bundle id.
    @Published var attachTo: Set<String> {
        didSet {
            // Saved only once the user changes it, so until then every browser
            // installed later is attached too (review F5).
            defaults.set(Array(attachTo).sorted(), forKey: "sidebar.browsers")
            // A browser no longer attached gets its windows' space back (review F1).
            giveSpaceBack { !attachTo.contains($0.bundleId) }
            tracker.browserBundleIds = attachTo
            tracker.frontAppMayHaveChanged()
        }
    }
    /// Hidden for now with the shortcut or the menu: the window gets its space
    /// back, and showing it again makes room again (like collapsing Arc's sidebar).
    @Published private(set) var collapsed: Bool
    /// The sidebar takes over the browser's tabs: its own tab strip is switched
    /// to collapsed vertical tabs (see TabStripTakeover), and with the sidebar
    /// on the left, the sidebar covers that column too.
    @Published var takeOverTabs: Bool { didSet { save(); stripCover = nil; takenOver = [:]; if takeOverTabs, let t = current { takeOver(t) }; layout() } }
    /// Shows and hides the sidebar while an attached browser is in front.
    @Published var shortcut: Shortcut { didSet { save(); hotKey.shortcut = shortcut; updateHotKey() } }

    @Published private(set) var trusted = WindowTracker.isTrusted
    /// The browser window the sidebar is bound to right now. Its `frame` is
    /// refreshed when the window, its title, or its resting place (settle)
    /// changes, not on every drag step, so a drag doesn't redraw the tab list;
    /// `current` has the live frame.
    @Published private(set) var target: WindowTracker.Target?
    @Published private(set) var placedSide: SidebarSide = .right

    private let tracker: WindowTracker
    private var panel: SidebarPanel?
    private var current: WindowTracker.Target?
    /// A window this sidebar resized, by window: the space the user gave the
    /// pair, and the frame the window took inside it.
    private struct Fit {
        var outer: CGRect, inner: CGRect, side: SidebarSide
        /// The window itself, to give it its space back later.
        var window: AXUIElement?
        var bundleId: String
        /// Its window-server number, which FitMemory knows it by.
        var number: UInt32?
    }
    /// Mirrored into `memory`, which outlives the app, so a window narrowed
    /// before a relaunch is still known as narrowed (review: geometry alone
    /// can't tell a narrowed window from a freshly snapped one).
    private var fits: [Int: Fit] = [:] {
        didSet {
            for (k, f) in oldValue where fits[k] == nil { if let n = f.number { memory.forget(window: n) } }
            for f in fits.values {
                if let n = f.number { memory.record(.init(bundleId: f.bundleId, window: n, inner: f.inner, outer: f.outer)) }
            }
            saveMemory()
        }
    }
    private var memory = FitMemory()
    /// The narrowest a browser let its window get, by window, once it stopped us.
    private var minWidths: [Int: CGFloat] = [:]
    private var askedAt = Date.distantPast
    /// The frame a window would not give up, so it isn't asked again.
    private var refused: CGRect?
    private var trustToken: NSObjectProtocol?
    private var activationToken: NSObjectProtocol?
    private let hotKey = SidebarHotKey()
    /// A separate domain while `BETTERLINK_HOME` is set, like the menu bar icon.
    private let defaults = MenuBarIcon.defaults()

    private init() {
        let attach = (defaults.array(forKey: "sidebar.browsers") as? [String]).map(Set.init) ?? Self.defaultBrowsers()
        tracker = WindowTracker(browserBundleIds: attach)
        attachTo = attach
        collapsed = defaults.bool(forKey: "sidebar.collapsed")
        shortcut = Shortcut.load(defaults, key: "sidebar.shortcut") ?? .sidebarDefault
        takeOverTabs = defaults.object(forKey: "sidebar.takeOverTabs") as? Bool ?? true
        enabled = defaults.bool(forKey: "sidebar.enabled")
        side = SidebarSide(rawValue: defaults.string(forKey: "sidebar.side") ?? "") ?? .right
        memory = defaults.data(forKey: "sidebar.fitMemory").flatMap { try? JSONDecoder().decode(FitMemory.self, from: $0) } ?? FitMemory()
        memory.prune(alive: WindowTracker.liveWindowNumbers())
        let w = defaults.double(forKey: "sidebar.width")
        width = w >= 200 ? w : 280
        tracker.onChange = { [weak self] t in self?.targetChanged(t) }
        tracker.onSettle = { [weak self] t in self?.settle(t) }
        tracker.onDragStart = { [weak self] in self?.panel?.windowNumber }
        hotKey.onPress = { [weak self] in self?.toggleCollapsed() }
        hotKey.shortcut = shortcut
        // betterlink's own window coming forward keeps the sidebar bound (the
        // tracker ignores it). The panel then drops to a normal level, just
        // above the browser window, so it stays beside the browser (the Side
        // and Width settings preview live) without floating over betterlink's
        // window; the browser coming back lifts it again.
        activationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.layout() } }
        // macOS posts this whenever any app's Accessibility permission changes.
        trustToken = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new value is readable a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { self?.trustMayHaveChanged() }
            }
        }
    }

    /// Called at launch: brings the sidebar back if it was on.
    func restore() { if enabled { start() } }

    func requestTrust() { WindowTracker.requestTrust() }

    /// Every installed Chromium browser, and Safari.
    static func defaultBrowsers() -> Set<String> {
        Set(AppModel.installedBrowsers().filter { $0.family == .chromium || $0.bundleId == "com.apple.Safari" }.map(\.bundleId))
    }

    /// The shortcut and the menu item: hide the sidebar and give the window its
    /// space back, or show it and make room again.
    func toggleCollapsed() {
        guard enabled else { return }
        DragTrace.log("toggle: collapsed \(collapsed) -> \(!collapsed)")
        if collapsed { slideIn() } else { slideOut() }
    }

    // MARK: - Show and hide as one slide

    /// A slide in progress: where the sidebar's outer edge is, the window's
    /// frames hidden and shown (equal when the window doesn't make room), and
    /// the timer stepping it.
    private struct SlideRun {
        var slide: SidebarSlide
        var side: SidebarSide
        var outer: CGFloat
        var hiddenWindow: CGRect
        var shownWindow: CGRect
        var windowHash: Int
        var timer: Timer?
        var frames = 0, started = CACurrentMediaTime(), worstGap: CGFloat = 0
        var fitted: Bool { hiddenWindow != shownWindow }
    }
    private var slideRun: SlideRun?

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Hides: the sidebar's inner edge and the window's edge slide toward the
    /// outer edge together; at the end the window fills the tile.
    private func slideOut() {
        collapsed = true
        save()
        if var run = slideRun { // turning back mid-show
            run.slide.hide(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
            slideRun = run
            return
        }
        guard let t = current, let panel, panel.isVisible, let attached = panel.attachedSide else {
            giveSpaceBack(); layout(); return
        }
        let visible = panel.frame
        let outer = attached == .left ? visible.minX : visible.maxX
        let fit = fits[t.windowHash].flatMap { Self.same($0.inner, t.frame) ? $0 : nil }
        var run = SlideRun(slide: SidebarSlide(shown: true), side: attached, outer: outer,
                           hiddenWindow: fit?.outer ?? t.frame, shownWindow: t.frame, windowHash: t.windowHash)
        run.slide.hide(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
        start(run)
    }

    /// Shows: the window narrows and the sidebar opens from its outer edge,
    /// together, the reverse of a hide.
    private func slideIn() {
        collapsed = false
        save()
        if var run = slideRun { // turning back mid-hide
            run.slide.show(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
            slideRun = run
            return
        }
        guard let t = current, !t.fullScreen else { layout(); return }
        // Where the window goes: narrowed to make room when it was given a
        // tile, else where it is.
        let screen = screen(for: t.frame)
        let inner = refused == nil ? SidebarGeometry.settled(window: t.frame, screen: screen, width: width, side: side,
                                                             minWindowWidth: minWidths[t.windowHash] ?? 500) : nil
        let shown = inner ?? t.frame
        let panel = placePanel(beside: shown, t)
        guard let attached = panel.attachedSide else { layout(); return }
        let outer = attached == .left ? panel.frame.minX : panel.frame.maxX
        if inner != nil {
            fits[t.windowHash] = Fit(outer: t.frame, inner: shown, side: attached,
                                     window: tracker.boundWindow, bundleId: t.bundleId, number: tracker.boundWindowNumber)
            askedAt = Date()
        }
        panel.reveal = outer
        panel.showNow()
        var run = SlideRun(slide: SidebarSlide(shown: false), side: attached, outer: outer,
                           hiddenWindow: t.frame, shownWindow: shown, windowHash: t.windowHash)
        run.slide.show(at: CACurrentMediaTime(), reduceMotion: reduceMotion)
        start(run)
    }

    private func start(_ run: SlideRun) {
        slideRun = run
        stepSlide()
        guard slideRun != nil else { return } // Reduce Motion: done in one step
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepSlide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        slideRun?.timer = timer
    }

    /// One frame: the window to its frame for this moment, then the sidebar
    /// revealed up to where the window really is, so the seam stays tight
    /// even when the browser lags behind.
    private func stepSlide() {
        guard var run = slideRun, let panel else { return }
        let now = CACurrentMediaTime()
        let p = run.slide.progress(at: now)
        let f = SidebarSlide.frames(hiddenWindow: run.hiddenWindow, shownWindow: run.shownWindow,
                                    outerEdge: run.outer, width: CGFloat(width), side: run.side, progress: p)
        var seam = f.innerEdge
        if run.fitted {
            tracker.slideWindow(to: f.window, moveOrigin: run.side == .left)
            if let real = tracker.windowServerFrame() {
                let edge = run.side == .left ? real.minX : real.maxX
                run.worstGap = max(run.worstGap, abs(edge - f.innerEdge))
                seam = edge
            }
        }
        panel.reveal = seam
        run.frames += 1
        if run.slide.done(at: now) {
            run.slide.settle(at: now)
            run.timer?.invalidate()
            slideRun = nil
            finishSlide(run)
            return
        }
        slideRun = run
    }

    private func finishSlide(_ run: SlideRun) {
        let ms = (CACurrentMediaTime() - run.started) * 1000
        DragTrace.log(String(format: "slide %@: %d frames in %.0f ms (%.0f fps), worst seam gap %.1f pt, window %@",
                             run.slide.phase == .hidden ? "out" : "in", run.frames, ms, Double(run.frames) / max(ms / 1000, 0.001),
                             run.worstGap, run.fitted ? "resized" : "unchanged"))
        if run.slide.phase == .hidden {
            // Closed first, then the mask lifted: the whole panel never flashes.
            panel?.hideNow()
            panel?.reveal = nil
            fits[run.windowHash] = nil
            giveSpaceBack() // any other window narrowed for the sidebar
        } else {
            panel?.reveal = nil
            layout()
        }
    }



    // MARK: - Lifecycle

    private func start() {
        trusted = WindowTracker.isTrusted
        guard trusted else { WindowTracker.requestTrust(); return }
        TabsModel.shared.start()
        tracker.start()
    }

    private func stop() {
        giveSpaceBack()
        minWidths = [:]
        hotKey.setRegistered(false)
        tracker.stop()
        panel?.orderOut(nil)
    }

    /// Gives every window the sidebar narrowed, not only the one in front, its
    /// space back, if it is still as narrowed. Also called when the app quits.
    func giveSpaceBack() { giveSpaceBack(where: { _ in true }) }

    private func giveSpaceBack(where include: (Fit) -> Bool) {
        for (k, f) in fits where include(f) {
            // A window that can't be read now (a hung browser) keeps its record,
            // so it is recognised later instead of narrowed again.
            guard let win = f.window, let now = tracker.currentFrame(of: win) else { continue }
            if Self.same(now, f.inner) { tracker.setWindowFrame(f.outer, of: win) }
            fits[k] = nil
        }
        // Removing a window from `fits` forgets its record. A window narrowed
        // before a relaunch that hasn't been reached again keeps its record
        // (it is still narrowed), so it is never narrowed twice (review N1).
    }

    /// The shortcut is registered only while an attached browser is the front
    /// app, so it never takes the keys from another app, betterlink's own
    /// shortcut setting included (review F2). layout() calls it, and runs on
    /// every app activation (activationToken).
    private func updateHotKey() {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        hotKey.setRegistered(enabled && current != nil && front == current?.pid)
        if hotKeyProblem != hotKey.problem { hotKeyProblem = hotKey.problem }
    }

    /// Why the shortcut couldn't be registered, for the setting.
    @Published private(set) var hotKeyProblem: String?

    private func saveMemory() {
        if let d = try? JSONEncoder().encode(memory) { defaults.set(d, forKey: "sidebar.fitMemory") }
    }

    private func trustMayHaveChanged() {
        let now = WindowTracker.isTrusted
        guard now != trusted else { return }
        trusted = now
        if enabled && now { start() }
    }

    private func save() {
        defaults.set(enabled, forKey: "sidebar.enabled")
        defaults.set(side.rawValue, forKey: "sidebar.side")
        defaults.set(width, forKey: "sidebar.width")
        defaults.set(collapsed, forKey: "sidebar.collapsed")
        shortcut.save(defaults, key: "sidebar.shortcut")
        defaults.set(takeOverTabs, forKey: "sidebar.takeOverTabs")
    }

    // MARK: - Layout

    private func targetChanged(_ t: WindowTracker.Target?) {
        let newWindow = t != nil && t?.windowHash != current?.windowHash
        current = t
        if newWindow, let t {
            // A window already taken over keeps its measurement: coming back
            // from another app neither drops the cover nor presses again.
            stripCover = takenOver[t.windowHash] ?? nil
            if takeOverTabs, takenOver[t.windowHash] == nil { takeOver(t) }
        }
        var shown = t
        if let old = target { shown?.frame = old.frame }
        if shown != target { target = t }
        layout()
    }

    /// The browser's collapsed vertical tab column, as (width, distance from
    /// the window's top), measured from the window; nil when there is none.
    private var stripCover: CGSize?
    /// Windows already taken over, with their measured column (nil inside
    /// when the window shows none), by window hash.
    private var takenOver: [Int: CGSize?] = [:]

    /// Collapses the bound window's tab strip (Chromium browsers), then
    /// measures the column it leaves, so the sidebar can cover it.
    ///
    /// The browser's menu acts on whichever of its windows is focused and only
    /// catches up a moment after a window comes forward, so nothing is pressed
    /// until the bound window is the browser's focused main window, and each
    /// step waits for the browser to lay the strip out. Turning vertical tabs on
    /// enables "Collapse" only after that, hence a second pass.
    private func takeOver(_ t: WindowTracker.Target, pass: Int = 0) {
        guard Browser.known(bundleId: t.bundleId)?.family == .chromium, pass < 3 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, self.takeOverTabs, self.current?.windowHash == t.windowHash else { return }
            guard self.tracker.boundWindowIsFocusedMain() else { return self.takeOver(t, pass: pass + 1) }
            if TabStripTakeover.apply(pid: t.pid) != nil { return self.takeOver(t, pass: pass + 1) }
            self.stripCover = self.tracker.verticalTabStrip()
            self.takenOver[t.windowHash] = .some(self.stripCover)
            self.layout()
        }
    }

    /// Frames within a point count as the same: the browser rounds.
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    private func screen(for frame: CGRect) -> CGRect {
        (NSScreen.screens.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area }
            ?? NSScreen.main)?.visibleFrame ?? frame
    }

    /// The window came to rest: make the pair fill the space the window was given.
    private func settle(_ t: WindowTracker.Target) {
        // The tab list matches the window by its frame: refresh it now that it is still.
        if target != t { target = t }
        // Every mouse-up settles: the user may have expanded the tab column or
        // turned vertical tabs off, so measure it again (review F3).
        if takeOverTabs, takenOver[t.windowHash] != nil {
            let now = tracker.verticalTabStrip()
            takenOver[t.windowHash] = .some(now)
            if now != stripCover { stripCover = now; layout() }
        }
        guard enabled, !collapsed, !t.fullScreen else { return }
        if let r = refused, !Self.same(r, t.frame) { refused = nil }
        var outer = t.frame
        if let f = fits[t.windowHash] {
            if Self.same(f.inner, t.frame) { return }
            if learnMinWidth(asked: f.inner, got: t) {
                outer = f.outer // the browser widened it again after we asked
            }
            fits[t.windowHash] = nil // otherwise the user moved, resized or snapped it again
        }
        guard refused == nil else { return }
        // Narrowed before (this launch or an earlier one) and not moved since: keep it.
        if fits[t.windowHash] == nil, let n = tracker.boundWindowNumber, let e = memory.fitted(t.frame, window: n) {
            fits[t.windowHash] = Fit(outer: e.outer, inner: t.frame,
                                     side: SidebarGeometry.resolve(side, window: e.outer, screen: screen(for: e.outer)),
                                     window: tracker.boundWindow, bundleId: t.bundleId, number: n)
            return layout()
        }
        fit(t, into: outer)
        layout()
    }

    /// Narrows the window so it and the sidebar fill `outer`. A browser that
    /// stops at its minimum width is asked once more, with that width known, so
    /// the pair stays on the screen.
    private func fit(_ t: WindowTracker.Target, into outer: CGRect) {
        let screen = screen(for: outer)
        for _ in 0..<2 {
            guard let inner = SidebarGeometry.settled(window: outer, screen: screen, width: width, side: side,
                                                      minWindowWidth: minWidths[t.windowHash] ?? 500) else { return }
            fits[t.windowHash] = Fit(outer: outer, inner: inner,
                                     side: SidebarGeometry.resolve(side, window: outer, screen: screen),
                                     window: tracker.boundWindow, bundleId: t.bundleId, number: tracker.boundWindowNumber)
            askedAt = Date()
            tracker.setWindowFrame(inner)
            guard let now = current, now.windowHash == t.windowHash else { return }
            if Self.same(now.frame, inner) { return }
            if learnMinWidth(asked: inner, got: now) { continue }
            if Self.same(now.frame, t.frame) {
                fits[t.windowHash] = nil
                refused = t.frame
            } else {
                fits[t.windowHash]?.inner = now.frame
            }
            return
        }
        if let now = current, now.windowHash == t.windowHash { fits[t.windowHash]?.inner = now.frame }
    }

    /// True when the window kept the place it was asked to take but is wider
    /// than asked, by a width not known yet: the browser's minimum. Only right
    /// after asking; later, it is the user widening the window.
    private func learnMinWidth(asked: CGRect, got t: WindowTracker.Target) -> Bool {
        guard Date().timeIntervalSince(askedAt) < 0.5, abs(t.frame.minX - asked.minX) < 2, abs(t.frame.height - asked.height) < 2,
              t.frame.width > asked.width + 2, t.frame.width > (minWidths[t.windowHash] ?? 0) + 2 else { return false }
        minWidths[t.windowHash] = t.frame.width
        return true
    }

    /// The side or width changed: start again from the space the pair was given.
    private func refit() {
        guard enabled, let t = current else { return }
        refused = nil
        if let f = fits[t.windowHash], Self.same(f.inner, t.frame) {
            fits[t.windowHash] = nil
            tracker.setWindowFrame(f.outer)
        }
        if let now = current { settle(now) }
        layout()
    }

    private func layout() {
        // The shortcut works only while an attached browser is in front.
        updateHotKey()
        // A slide places the panel itself, frame by frame.
        guard slideRun == nil else { return }
        let ownAppInFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard enabled, !collapsed, let t = current, !t.fullScreen else {
            panel?.fadeOut()
            return
        }
        let panel = placePanel(beside: t.frame, t)
        if ownAppInFront {
            // Beside the browser window, under betterlink's own windows; with
            // no window number to order against, hidden rather than on top.
            guard let n = tracker.boundWindowNumber else { panel.fadeOut(); return }
            if panel.level != .normal { panel.level = .normal }
            panel.fadeIn()
            panel.order(.above, relativeTo: Int(n))
        } else {
            if panel.level != .floating { panel.level = .floating }
            panel.fadeIn()
        }
    }

    /// Puts the panel beside a window at `windowFrame` (the bound window's,
    /// or where it is about to be), attached to its edge. Returns the panel.
    @discardableResult
    private func placePanel(beside windowFrame: CGRect, _ t: WindowTracker.Target) -> SidebarPanel {
        let fit = fits[t.windowHash].flatMap { Self.same($0.inner, windowFrame) ? $0 : nil }
        let p = SidebarGeometry.place(window: windowFrame, screen: screen(for: windowFrame), width: width, side: fit?.side ?? side,
                                      keepOnScreen: refused.map { Self.same($0, windowFrame) } ?? false)
        if placedSide != p.side { placedSide = p.side }
        let panel = self.panel ?? makePanel()
        let attached: SidebarSide? = p.overlaps ? nil : p.side
        // On the left, it also covers the browser's collapsed tab column.
        panel.attach(to: attached, cover: attached == .left && takeOverTabs ? stripCover : nil)
        // Beside the window, the panel reaches under the window's rounded
        // corners to fill them (see SidebarPanel), so it is that much wider.
        let reach = attached == nil ? 0 : panel.reach
        var frame = p.sidebar
        frame.size.width += reach
        if attached == .right { frame.origin.x -= reach }
        // Set first: the move notifications arrive inside setFrame.
        placedPanelFrame = frame
        // A pure move is cheap; only a real resize lays the tab list out again.
        if panel.frame.size == frame.size {
            panel.setFrameOrigin(frame.origin)
        } else {
            panel.setFrame(frame, display: true, animate: false)
        }
        return panel
    }

    private func makePanel() -> SidebarPanel {
        let host = NSHostingView(rootView: SidebarView().environmentObject(self))
        // The browser window sets the panel's size; the content must never grow it.
        host.sizingOptions = []
        let panel = SidebarPanel(contentView: host)
        panel.setTint(tint)
        self.panel = panel
        panelTokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChangedAt = Date() }
        })
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            panelTokens.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panelFrameChanged() }
            })
        }
        return panel
    }

    // MARK: - Moved from outside

    /// The frame layout() last gave the panel. Any other frame came from
    /// outside: a window-snapping tool or anything else using Accessibility.
    private var placedPanelFrame: CGRect?
    private var panelTokens: [NSObjectProtocol] = []
    private var outsideMove: DispatchWorkItem?
    private var screensChangedAt = Date.distantPast

    /// A snap or move aimed at the sidebar is meant for the pair: once the
    /// tool is done (it may set the position and the size separately), the
    /// browser window and the sidebar fill the panel's new frame together, the
    /// sidebar keeping its width on its side, as snapping the browser does.
    private func panelFrameChanged() {
        guard let panel, let placed = placedPanelFrame, !Self.same(panel.frame, placed) else { return }
        // macOS moves windows itself when displays change; that is no snap.
        guard Date().timeIntervalSince(screensChangedAt) > 1 else { return }
        outsideMove?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.movePairToPanel() } }
        outsideMove = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func movePairToPanel() {
        guard let panel, let placed = placedPanelFrame, !Self.same(panel.frame, placed),
              enabled, !collapsed, let t = current, !t.fullScreen else { return }
        let rect = panel.frame
        let side: SidebarSide = placedSide == .left ? .left : .right
        let inner = SidebarGeometry.windowAfterPanelMoved(from: placed, to: rect, window: t.frame, width: width, side: side,
                                                          minWindowWidth: minWidths[t.windowHash] ?? 500)
        if abs(rect.width - placed.width) >= 2 {
            // Given a tile: hiding the sidebar later gives the browser all of it.
            fits[t.windowHash] = Fit(outer: rect, inner: inner, side: side,
                                     window: tracker.boundWindow, bundleId: t.bundleId, number: tracker.boundWindowNumber)
        } else if var f = fits[t.windowHash] {
            // Carried along: the space to give back moves with the window.
            f.outer = CGRect(x: f.outer.minX + inner.minX - t.frame.minX, y: inner.minY, width: f.outer.width, height: inner.height)
            f.inner = inner
            fits[t.windowHash] = f
        }
        askedAt = Date()
        tracker.setWindowFrame(inner)
        layout()
    }

    // MARK: - Actions from the sidebar

    /// Paints the sidebar in the browser profile's frame color (nil: the
    /// standard sidebar material), so it reads as part of that window.
    func setTint(_ rgb: UInt32?) {
        let p = rgb.map { SidebarPalette(profileColor: $0) }
        if palette != p { palette = p }
        tint = p?.background.hex
        panel?.setTint(tint)
    }
    private var tint: UInt32?
    /// Readable colors for the profile color (WCAG AA), or nil for the standard look.
    @Published private(set) var palette: SidebarPalette?

    /// After a click or a typed link in the sidebar, hand the keyboard back to the browser.
    func returnFocusToBrowser() { tracker.activateBrowser() }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// The continuous ("squircle") corner macOS draws on windows, as an outline.
/// AppKit has no API for that path, so it is read once from a CALayer with
/// `cornerCurve = .continuous`, rendered at 8x: for each step down from the
/// edge, how far in the corner's curve starts.
struct ContinuousCorner {
    /// (distance from the edge, how far the curve is set in at that distance), in points.
    let profile: [(CGFloat, CGFloat)]
    /// How far along each edge the curve reaches.
    var extent: CGFloat { profile.first?.1 ?? 0 }

    init(radius r: CGFloat) {
        let scale: CGFloat = 8, size = Int(r * 3 * scale)
        guard r > 0, let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data else { profile = []; return }
        ctx.scaleBy(x: scale, y: scale)
        let l = CALayer()
        l.frame = CGRect(x: 0, y: 0, width: r * 3, height: r * 3)
        l.backgroundColor = CGColor(gray: 0, alpha: 1)
        l.cornerRadius = r
        l.cornerCurve = .continuous
        l.render(in: ctx)
        let a = data.assumingMemoryBound(to: UInt8.self)
        var out: [(CGFloat, CGFloat)] = []
        for row in 0..<(size / 2) {
            // Coverage of the transparent run at the start of this row, in pixels.
            var clear: CGFloat = 0
            for x in 0..<(size / 2) {
                let alpha = CGFloat(a[row * size + x]) / 255
                if alpha >= 0.999 { break }
                clear += 1 - alpha
            }
            out.append((CGFloat(row) / scale, clear / scale))
            if clear == 0 { break }
        }
        profile = out
    }

    /// The outline of the bit of a `w`-wide strip, standing on the edge of a
    /// window whose corner this is, that the corner leaves uncovered. Panel
    /// coordinates: the window's edge at `edgeX`, the window to the left when
    /// `windowLeft`, the corner at the top (`top` true) or bottom.
    func notch(edgeX: CGFloat, windowLeft: Bool, top: Bool, height h: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let y = { (d: CGFloat) in top ? h - d : d }
        let x = { (inset: CGFloat) in windowLeft ? edgeX - inset : edgeX + inset }
        p.move(to: CGPoint(x: edgeX, y: y(0)))
        for (d, inset) in profile { p.addLine(to: CGPoint(x: x(inset), y: y(d))) }
        p.addLine(to: CGPoint(x: edgeX, y: y(profile.last?.0 ?? 0)))
        p.closeSubpath()
        return p
    }

    /// A rect whose chosen corners follow this curve; the others stay square.
    /// Corners: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left (y up).
    func rect(_ r: CGRect, corners: Set<Int>) -> CGPath {
        var path = CGPath(rect: r, transform: nil)
        let all: [(Int, CGPoint, CGFloat, CGFloat)] = [(0, CGPoint(x: r.minX, y: r.maxY), 1, -1), (1, CGPoint(x: r.maxX, y: r.maxY), -1, -1),
                                                       (2, CGPoint(x: r.maxX, y: r.minY), -1, 1), (3, CGPoint(x: r.minX, y: r.minY), 1, 1)]
        for (i, o, sx, sy) in all where corners.contains(i) {
            // The sliver between the rect's corner point and the curve.
            let cut = CGMutablePath()
            cut.move(to: o)
            for (d, inset) in profile { cut.addLine(to: CGPoint(x: o.x + sx * inset, y: o.y + sy * d)) }
            cut.addLine(to: CGPoint(x: o.x, y: o.y + sy * (profile.last?.0 ?? 0)))
            cut.closeSubpath()
            path = path.subtracting(cut)
        }
        return path
    }
}

/// A borderless, non-activating panel: clicking it never takes the browser out
/// of the front, but it can still take keyboard focus for its text field.
///
/// Beside a browser window it reaches `browserCornerRadius` under the window's
/// edge and draws only where the window's rounded corners leave the screen
/// showing, so the two read as one window with no notch at the seam. The rest
/// of that strip is fully transparent, so clicks there reach the browser.
final class SidebarPanel: NSPanel {
    override func orderOut(_ sender: Any?) {
        fadeTimer?.invalidate(); fadeTimer = nil
        fade = Fade(shown: false)
        if DragTrace.enabled {
            let caller = Thread.callStackSymbols.dropFirst().prefix(4).map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).prefix(1).joined() }
            DragTrace.log("orderOut alpha \(alphaValue) from \(caller.joined(separator: " < "))")
        }
        super.orderOut(sender)
    }

    /// The corner of a macOS 26 browser window: a continuous curve, measured on
    /// Chrome (its alpha along the corner matches a 21 pt continuous rounded rect).
    static let corner = ContinuousCorner(radius: 21)
    /// How far the panel reaches under the browser window: as far as the
    /// corner's curve runs along the edge.
    static var browserCornerRadius: CGFloat { ceil(corner.extent) }

    private let effect = NSVisualEffectView()
    private let shape = CAShapeLayer()
    /// The profile color, under the content and inside the same mask.
    private let tint = NSView()
    private var leading: NSLayoutConstraint?
    private var trailing: NSLayoutConstraint?
    private var side: SidebarSide?
    private var cover: CGSize?
    /// How far the panel reaches under the browser window: the corner's curve,
    /// or the tab column it covers when wider.
    var reach: CGFloat { max(Self.browserCornerRadius, cover?.width ?? 0) }

    init(contentView content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        // No shadow of its own: it would fall across the browser along the seam,
        // and the pair should read as one window.
        hasShadow = false
        // Our slide and fade are the only motion; no system fade on close.
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.mask = shape
        tint.wantsLayer = true
        tint.isHidden = true
        tint.autoresizingMask = [.width, .height]
        effect.addSubview(tint)
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        leading = content.leadingAnchor.constraint(equalTo: effect.leadingAnchor)
        trailing = content.trailingAnchor.constraint(equalTo: effect.trailingAnchor)
        NSLayoutConstraint.activate([
            leading!, trailing!,
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    func setTint(_ rgb: UInt32?) {
        tint.frame = effect.bounds
        tint.isHidden = rgb == nil
        if let rgb {
            tint.layer?.backgroundColor = CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                                  blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        }
    }

    /// Which side of the browser window the panel is on, or nil when it covers
    /// the window's edge instead (all four corners rounded, nothing to fill).
    func attach(to side: SidebarSide?, cover: CGSize? = nil) {
        self.side = side
        self.cover = side == .left ? cover : nil
        let r = side == nil ? 0 : reach
        leading?.constant = side == .right ? r : 0
        trailing?.constant = side == .left ? -r : 0
        reshape()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        reshape()
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(frameRect, display: displayFlag, animate: animateFlag)
        reshape()
    }

    /// The sidebar with rounded outer corners, plus the bits of the strip under
    /// the browser's edge that its rounded corners leave uncovered.
    /// During a slide, the part of the panel shown: from `inner` (the
    /// window's seam) to the outer edge, in screen x. Nil: the whole panel.
    var reveal: CGFloat? { didSet { reshape() } }

    private func reshape() {
        let b = effect.bounds
        guard b.width > 0, b.height > 0 else { return }
        let reach = self.reach, c = Self.corner
        var path: CGPath
        if let inner = reveal {
            // Only the strip between the seam and the outer edge, outer
            // corners rounded; the content stays anchored and isn't reflowed.
            let x = min(max(inner - frame.minX, 0), b.width)
            let strip = side == .left ? CGRect(x: 0, y: 0, width: x, height: b.height)
                                      : CGRect(x: x, y: 0, width: b.width - x, height: b.height)
            path = strip.width < 1 ? CGPath(rect: .zero, transform: nil)
                                   : c.rect(strip, corners: side == .left ? [0, 3] : [1, 2])
            CATransaction.begin(); CATransaction.setDisableActions(true)
            shape.frame = b; shape.path = path
            CATransaction.commit()
            return
        }
        switch side {
        case .right:
            // The window is to the left; its edge is at x = reach.
            let body = c.rect(CGRect(x: reach, y: 0, width: b.width - reach, height: b.height), corners: [1, 2])
            path = body.union(c.notch(edgeX: reach, windowLeft: true, top: true, height: b.height))
                .union(c.notch(edgeX: reach, windowLeft: true, top: false, height: b.height))
        case .left:
            let edge = b.width - reach
            let body = c.rect(CGRect(x: 0, y: 0, width: edge, height: b.height), corners: [0, 3])
            path = body.union(c.notch(edgeX: edge, windowLeft: false, top: true, height: b.height))
                .union(c.notch(edgeX: edge, windowLeft: false, top: false, height: b.height))
            // The browser's collapsed tab column, from its top to the window's bottom.
            if let cover, cover.height < b.height {
                path = path.union(CGPath(rect: CGRect(x: edge, y: 0, width: cover.width, height: b.height - cover.height), transform: nil))
            }
        default:
            path = c.rect(b, corners: [0, 1, 2, 3])
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = b
        shape.path = path
        CATransaction.commit()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The show and hide fade (BetterlinkCore's Fade), stepped by our own
    /// timer: AppKit's window alpha animation sometimes didn't run on hide,
    /// leaving the panel to vanish at once (Nick, 2026-11-24).
    private var fade = Fade(shown: false)
    private var fadeTimer: Timer?

    private static var now: Double { CACurrentMediaTime() }

    /// The side the panel is attached on, nil when it covers the window's edge.
    var attachedSide: SidebarSide? { side }

    /// Shows at full alpha at once (a slide reveals it instead of a fade).
    func showNow() {
        fadeTimer?.invalidate(); fadeTimer = nil
        fade = Fade(shown: true)
        alphaValue = 1
        if !isVisible { orderFrontRegardless() }
    }

    /// Hides at once, at the end of a slide.
    func hideNow() {
        fadeTimer?.invalidate(); fadeTimer = nil
        super.orderOut(nil)
        fade = Fade(shown: false)
        alphaValue = 1
    }

    /// Shows the panel with a short fade (none with Reduce Motion).
    func fadeIn() {
        guard fade.phase == .hidden || fade.phase == .hiding || !isVisible else { return }
        if !isVisible { fade = Fade(shown: false); alphaValue = 0; orderFrontRegardless() }
        DragTrace.log("fadeIn from alpha \(alphaValue) phase \(fade.phase)")
        fade.show(at: Self.now, reduceMotion: Self.reduceMotion)
        runFade()
    }

    /// Hides the panel with a short fade; a fadeIn during it wins.
    func fadeOut() {
        guard isVisible, fade.phase == .shown || fade.phase == .showing else { return }
        DragTrace.log("fadeOut from alpha \(alphaValue) phase \(fade.phase)")
        fade.hide(at: Self.now, reduceMotion: Self.reduceMotion)
        runFade()
    }

    private func runFade() {
        step()
        guard fadeTimer == nil, fade.phase == .showing || fade.phase == .hiding else { return }
        let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
        RunLoop.main.add(t, forMode: .common) // keeps stepping during drags and menus
        fadeTimer = t
    }

    private func step() {
        let t = Self.now
        alphaValue = fade.alpha(at: t)
        guard fade.done(at: t) else { return }
        fade.settle(at: t)
        fadeTimer?.invalidate(); fadeTimer = nil
        if fade.phase == .hidden {
            DragTrace.log("fade done: orderOut")
            super.orderOut(nil)
            alphaValue = 1
        }
    }
}
