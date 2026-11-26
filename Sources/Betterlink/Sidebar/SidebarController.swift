import AppKit
import BetterlinkCore
import Combine
import SwiftUI
import TabSyncCore

/// The betterlink sidebar: a panel beside every main window of every attached
/// browser, each moving with its window and showing that window's tabs
/// (SidebarInstance). Here: the settings they share, which of the browser's
/// own windows each one is, and their places on screen. Settings live in
/// UserDefaults (they describe this Mac's screen, not rules).
@MainActor
final class SidebarController: ObservableObject {
    static let shared = SidebarController()

    @Published var enabled: Bool { didSet { save(); enabled ? start() : stop() } }
    @Published var side: SidebarSide { didSet { save(); instances.values.forEach { $0.refit() } } }
    /// The browsers the sidebar attaches to, by bundle id.
    @Published var attachTo: Set<String> {
        didSet {
            // Saved only once the user changes it, so until then every browser
            // installed later is attached too (review F5).
            defaults.set(Array(attachTo).sorted(), forKey: "sidebar.browsers")
            // A browser no longer attached is let go: its windows get their
            // space back (review F1).
            tracker.browserBundleIds = attachTo
        }
    }
    /// The sidebar takes over the browser's tabs: its own tab strip is switched
    /// to collapsed vertical tabs (see TabStripTakeover); the sidebar sits
    /// beside that column, never over it.
    @Published var takeOverTabs: Bool { didSet { save(); takenOver = []; takeOverFront() } }
    /// Shows and hides the sidebar of the window in front, while an attached
    /// browser is in front.
    @Published var shortcut: Shortcut { didSet { save(); hotKey.shortcut = shortcut; updateHotKey() } }

    @Published private(set) var trusted = WindowTracker.isTrusted
    /// False when this macOS no longer says which window is which
    /// (`AXWindow.number`): then no window gets a sidebar.
    let canTellWindowsApart = AXWindow.numbersWindows
    /// Why the shortcut couldn't be registered, for the setting.
    @Published private(set) var hotKeyProblem: String?

    /// What a window gets when nothing was chosen for it: hidden or shown
    /// (`betterlink sidebar settings set --shown`, or the menu item with no
    /// browser in front), and how wide (the last width an edge was dragged to).
    private(set) var collapsed: Bool
    private(set) var width: Double

    let tracker: WindowTracker
    /// A sidebar for each window followed, by `WindowTracker.Target.id`.
    private var instances: [Int: SidebarInstance] = [:]
    /// The windows the sidebar has narrowed. It outlives the app, so a window
    /// narrowed before a relaunch is still known as narrowed (review: geometry
    /// alone can't tell a narrowed window from a freshly snapped one).
    private var memory = FitMemory()
    /// What was chosen for single windows: hidden or shown, and the width.
    private var chosen = WindowMemory()
    /// When macOS last rearranged the displays: it moves windows itself then.
    private(set) var screensChangedAt = Date.distantPast
    private var tokens: [NSObjectProtocol] = []
    private let hotKey = SidebarHotKey()
    /// A separate domain while `BETTERLINK_HOME` is set, like the menu bar icon.
    private let defaults = MenuBarIcon.defaults()

    private init() {
        let attach = (defaults.array(forKey: "sidebar.browsers") as? [String]).map(Browser.sidebarHosts) ?? Self.defaultBrowsers()
        tracker = WindowTracker(browserBundleIds: attach)
        attachTo = attach
        collapsed = defaults.bool(forKey: "sidebar.collapsed")
        shortcut = Shortcut.load(defaults, key: "sidebar.shortcut") ?? .sidebarDefault
        takeOverTabs = defaults.object(forKey: "sidebar.takeOverTabs") as? Bool ?? true
        enabled = defaults.bool(forKey: "sidebar.enabled")
        side = SidebarSide(rawValue: defaults.string(forKey: "sidebar.side") ?? "") ?? .right
        let w = defaults.double(forKey: "sidebar.width")
        width = w >= 200 ? w : 280
        memory = defaults.data(forKey: "sidebar.fitMemory").flatMap { try? JSONDecoder().decode(FitMemory.self, from: $0) } ?? FitMemory()
        chosen = defaults.data(forKey: "sidebar.windowMemory").flatMap { try? JSONDecoder().decode(WindowMemory.self, from: $0) } ?? WindowMemory()
        let alive = WindowServer.all()
        memory.prune(alive: alive)
        chosen.prune(alive: alive)
        tracker.onAdded = { [weak self] w in self?.added(w) }
        tracker.onRemoved = { [weak self] w, closed in self?.removed(w, closed: closed) }
        tracker.onChange = { [weak self] t in self?.changed(t) }
        tracker.onSettle = { [weak self] t in self?.settled(t) }
        tracker.onFocus = { [weak self] in self?.focusChanged() }
        tracker.onScreen = { [weak self] settled in self?.arrange(settled: settled) }
        tracker.onDragStart = { [weak self] id in self?.instances[id]?.panel?.windowNumber }
        hotKey.onPress = { [weak self] in self?.toggle() }
        hotKey.shortcut = shortcut
        tokens.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChangedAt = Date() }
        })
        // macOS posts this whenever any app's Accessibility permission changes.
        tokens.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            // The new value is readable a moment after the notification.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                MainActor.assumeIsolated { self?.trustMayHaveChanged() }
            }
        })
        applyForAll() // set while betterlink wasn't running
    }

    /// Called at launch: brings the sidebar back if it was on.
    func restore() { if enabled { start() } }

    func requestTrust() { WindowTracker.requestTrust() }

    /// Every installed browser the sidebar can attach to.
    static func defaultBrowsers() -> Set<String> {
        Set(AppModel.installedBrowsers().filter(\.hostsSidebar).map(\.bundleId))
    }

    /// Picks up settings another process wrote (`betterlink sidebar settings
    /// set`, through AgentCommand): only what differs is set, so each change
    /// takes effect as it does from the Sidebar page.
    func reloadSettings() {
        if let a = (defaults.array(forKey: "sidebar.browsers") as? [String]).map(Browser.sidebarHosts), a != attachTo { attachTo = a }
        if let s = SidebarSide(rawValue: defaults.string(forKey: "sidebar.side") ?? ""), s != side { side = s }
        let take = defaults.object(forKey: "sidebar.takeOverTabs") as? Bool ?? true
        if take != takeOverTabs { takeOverTabs = take }
        let on = defaults.bool(forKey: "sidebar.enabled")
        if on != enabled { enabled = on }
        applyForAll()
    }

    /// `--shown` and `--width` are for every window, also one that had its own:
    /// AgentTabs marks them, since the saved value alone may not have changed.
    /// Hiding and showing slide as the shortcut does.
    private func applyForAll() {
        if defaults.bool(forKey: "sidebar.shownForAll") {
            defaults.removeObject(forKey: "sidebar.shownForAll")
            setCollapsed(defaults.bool(forKey: "sidebar.collapsed"))
        }
        let w = defaults.double(forKey: "sidebar.width")
        if defaults.bool(forKey: "sidebar.widthForAll"), w >= 200 {
            defaults.removeObject(forKey: "sidebar.widthForAll")
            width = w
            chosen.forgetWidths()
            saveChosen()
            instances.values.forEach { $0.setWidth(w) }
        }
    }

    // MARK: - Show and hide

    /// The window the shortcut and the menu item act on: the focused window of
    /// the attached browser in front.
    private var front: SidebarInstance? { tracker.frontWindow.flatMap { instances[$0.id] } }

    /// The menu item: for the window in front, or with no browser in front for
    /// every window.
    var toggleTitle: String {
        if let i = front { return i.hidden ? "Show Sidebar" : "Hide Sidebar" }
        return collapsed ? "Show Sidebars" : "Hide Sidebars"
    }

    /// The shortcut and the menu item: hide the sidebar and give the window its
    /// space back, or show it and make room again.
    func toggle() {
        guard enabled else { return }
        guard let i = front else { return setCollapsed(!collapsed) }
        i.toggle()
        chosen.set(hidden: i.hidden, window: i.window.number, pid: i.window.target.pid)
        saveChosen()
    }

    /// Every window's sidebar, and those of windows still to come.
    private func setCollapsed(_ hide: Bool) {
        collapsed = hide
        defaults.set(hide, forKey: "sidebar.collapsed")
        chosen.forgetHidden()
        saveChosen()
        for i in instances.values where i.hidden != hide { i.toggle() }
    }

    /// The shortcut is registered only while an attached browser is the front
    /// app, so it never takes the keys from another app, betterlink's own
    /// shortcut setting included (review F2).
    private func updateHotKey() {
        hotKey.setRegistered(enabled && front != nil)
        if hotKeyProblem != hotKey.problem { hotKeyProblem = hotKey.problem }
    }

    // MARK: - Lifecycle

    /// The tab sync, while the sidebar is on.
    private var feeds: [AnyCancellable] = []
    private var sessions: [BrowserSession] = []
    private var profiles: [String: SidebarLook.Profile] = [:]
    private var ledger = HoldLedger()

    private func start() {
        trusted = WindowTracker.isTrusted
        guard trusted else { WindowTracker.requestTrust(); return }
        TabsModel.shared.start()
        if feeds.isEmpty {
            // @Published says what is about to be set: use what the sink is given.
            feeds = [
                TabsModel.shared.$sessions.sink { [weak self] s in
                    self?.sessions = s
                    self?.pair()
                },
                TabsModel.shared.$profiles.sink { [weak self] p in
                    self?.profiles = p.mapValues { SidebarLook.Profile(ref: $0.ref, name: $0.name, color: $0.color) }
                    self?.refreshLooks()
                },
                SidebarHoldsModel.shared.$ledger.sink { [weak self] l in
                    self?.ledger = l
                    self?.refreshLooks()
                },
            ]
        }
        tracker.start()
    }

    private func stop() {
        feeds = []
        tracker.stop() // lets every window go: each gets its space back (removed)
        takenOver = []
        arrange()
    }

    /// Gives every window the sidebar narrowed its space back, if it is still
    /// as narrowed. Called when the app quits. A browser that doesn't answer
    /// for one window isn't asked about its others (they keep their records):
    /// each would wait out its time while the app is quitting.
    func giveSpaceBack() {
        var hung: Set<pid_t> = []
        for i in instances.values where !hung.contains(i.window.target.pid) {
            if !i.giveSpaceBack(), AXWindow.timedOut { hung.insert(i.window.target.pid) }
        }
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
        shortcut.save(defaults, key: "sidebar.shortcut")
        defaults.set(takeOverTabs, forKey: "sidebar.takeOverTabs")
    }

    private func saveMemory() {
        if let d = try? JSONEncoder().encode(memory) { defaults.set(d, forKey: "sidebar.fitMemory") }
    }

    private func saveChosen() {
        if let d = try? JSONEncoder().encode(chosen) { defaults.set(d, forKey: "sidebar.windowMemory") }
    }

    // MARK: - Windows

    private func added(_ w: TrackedWindow) {
        let t = w.target
        instances[w.id] = SidebarInstance(window: w, sidebar: self,
                                          hidden: chosen.hidden(window: w.number, pid: t.pid) ?? collapsed,
                                          width: chosen.width(window: w.number, pid: t.pid) ?? width)
        pair()
        arrange()
    }

    /// `closed`: the window is gone; else only no longer followed, and it gets
    /// its space back.
    private func removed(_ w: TrackedWindow, closed: Bool) {
        guard let i = instances.removeValue(forKey: w.id) else { return }
        i.close(closed: closed)
        takenOver.remove(w.id)
        if closed {
            memory.forget(window: w.number)
            chosen.forget(window: w.number)
            saveMemory()
            saveChosen()
        }
        pair()
        arrange()
    }

    private func changed(_ t: WindowTracker.Target) {
        guard let i = instances[t.id] else { return }
        let was = i.reported
        i.reported = t
        if was.title != t.title { pair() }
        // Minimized, full screen or hidden, or back: its sidebar goes or comes.
        // Else it only moved, and the panel with it.
        if was.fullScreen != t.fullScreen || was.minimized != t.minimized || was.appHidden != t.appHidden {
            if was.fullScreen != t.fullScreen { i.readCorner(t.fullScreen ? "full screen" : "out of full screen") }
            tracker.orderMayHaveChanged()
        } else {
            i.follow()
        }
    }

    private func settled(_ t: WindowTracker.Target) {
        guard let i = instances[t.id] else { return }
        i.settle(t)
        pair() // by where it rests now
    }

    private func focusChanged() {
        pair()
        takeOverFront()
        updateHotKey()
    }

    /// Records what `window` has lent: only what was really lent (a window
    /// asked and not narrowed is as it was), and nothing once it has it back.
    func loanChanged(_ loan: WidthLoan?, of w: TrackedWindow) {
        if let loan {
            guard loan.phase == .lent else { return }
            memory.record(.init(bundleId: w.target.bundleId, window: w.number, inner: loan.inner, outer: loan.outer))
        } else {
            memory.forget(window: w.number)
        }
        saveMemory()
    }

    /// The record of a window narrowed before (this launch or an earlier one)
    /// that is still exactly as narrowed.
    func narrowedBefore(_ w: TrackedWindow, at frame: CGRect) -> FitMemory.Entry? { memory.fitted(frame, window: w.number) }

    /// A drag gave one window's sidebar this width: windows still to come take
    /// it too, and the others keep theirs, across a relaunch as well.
    func widthChosen(_ w: Double, for i: SidebarInstance) {
        for other in Array(instances.values) + [i] {
            chosen.set(width: other.width, window: other.window.number, pid: other.window.target.pid)
        }
        width = w
        defaults.set(w, forKey: "sidebar.width")
        saveChosen()
    }

    // MARK: - Which tabs

    private var pairing = WindowPairing()
    private var found: [Int: WindowPairing.Found] = [:]
    private var pairAgain: DispatchWorkItem?

    /// Works out again which of the browsers' own windows each window is
    /// (WindowPairing), then what each sidebar shows: whenever either side
    /// says something new (the tab lists, a window's title, its resting
    /// place, the focus, a window coming or going).
    private func pair() {
        guard let h = NSScreen.screens.first?.frame.height else { return }
        let windows = instances.values.sorted { $0.window.id < $1.window.id }.map { i -> WindowPairing.Window in
            let t = i.window.target
            let ax = SidebarGeometry.ax(fromCocoa: i.rest, mainScreenHeight: h)
            return .init(id: t.id, pid: Int(t.pid), app: t.appName,
                         frame: WindowBounds(left: ax.minX, top: ax.minY, width: ax.width, height: ax.height),
                         title: t.title, focused: i.window.isFocused)
        }
        found = pairing.update(windows, in: sessions, now: CACurrentMediaTime())
        refreshLooks()
        // A word on the focus counts once it has held: one more look then.
        pairAgain?.cancel()
        pairAgain = pairing.settlesAt.map { at in
            let work = DispatchWorkItem { [weak self] in self?.pair() }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at - CACurrentMediaTime()) + 0.01, execute: work)
            return work
        }
    }

    /// Only the sidebars on screen, and each only when what it shows differs:
    /// a tab changing in one window redraws no other window's sidebar.
    private func refreshLooks() {
        for i in instances.values where i.isShown {
            let t = i.window.target
            i.show(.make(found[t.id] ?? .unseen, pid: Int(t.pid), app: t.appName, sessions: sessions, profiles: profiles, ledger: ledger))
        }
    }

    // MARK: - On screen

    func isOnScreen(_ w: TrackedWindow) -> Bool { WindowServer.onScreen().contains(w.number) }

    /// Puts every sidebar in its place: beside its window and next to it among
    /// the other windows, or out of sight. `settled`: a moment after the event,
    /// when windows and Spaces have stopped moving. Reads the window list once
    /// for all of them, and only on an event.
    func arrange(settled: Bool = false) {
        if !instances.isEmpty {
            let onScreen = WindowServer.onScreen()
            for i in instances.values { i.present(onScreen: onScreen, settled: settled) }
        }
        // What tabs show keeps to the moment only while someone can be
        // watching it change: a sidebar on screen and a browser in front.
        let interval = PublishPacer.interval(sidebarOnScreen: instances.values.contains(where: \.isShown), browserInFront: tracker.browserInFront)
        if TabsModel.shared.interval != interval { TabsModel.shared.interval = interval }
        refreshLooks()
        updateHotKey()
    }

    // MARK: - Taking over the tabs

    /// Windows already taken over, by id.
    private var takenOver: Set<Int> = []
    /// Windows with a takeover run in progress, by id.
    private var takingOver: Set<Int> = []
    /// Browsers (bundle ids) where a press did not do what it was for: their
    /// tab strips are left alone for the rest of this launch.
    private var takeoverGaveUp: Set<String> = []

    /// The window that has the focus, its browser in front: the only one the
    /// browser's menu acts on. Each window gets its run when it comes forward.
    private func takeOverFront() {
        guard takeOverTabs, let w = tracker.frontWindow, instances[w.id] != nil, !takenOver.contains(w.id) else { return }
        takeOver(w)
    }

    /// Switches a window's tab strip to vertical tabs and collapses it
    /// (Chromium browsers). The sidebar sits beside the collapsed column and
    /// never covers it (Nick, 2026-11-24).
    ///
    /// One look at a time (`TabStripTakeoverFlow`), each from what the window
    /// is seen to be (`TabStripReading`): an item is pressed only when the
    /// window shows the other state, and the next looks check the press did
    /// what it was for. Seen not to have, it is pressed back and that browser
    /// is left alone. A window whose state can't be seen is left as it is (Nick,
    /// 2026-11-25: Brave with vertical tabs on was switched back and forth on
    /// every return).
    ///
    /// The browser's menu acts on whichever of its windows is focused and only
    /// catches up a moment after a window comes forward, so nothing is read or
    /// pressed until this window is the focused main window of the browser in
    /// front, and each look waits for the browser to lay the strip out.
    private func takeOver(_ w: TrackedWindow) {
        // One run per window at a time: a second, started on coming back to the
        // window within a look, would press what the first just pressed.
        guard Browser.known(bundleId: w.target.bundleId)?.family == .chromium, !takeoverGaveUp.contains(w.target.bundleId),
              takingOver.insert(w.id).inserted else { return }
        takeOverLook(w, look: 0, flow: .init())
    }

    private func takeOverLook(_ w: TrackedWindow, look: Int, flow: TabStripTakeoverFlow) {
        let id = w.id
        guard look < 20 else { takingOver.remove(id); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self, weak w] in
            guard let self else { return }
            // Another window or app came forward, this one closed, or the
            // setting went off: the run ends here, and the next time starts
            // from what the window then shows.
            guard let w, self.takeOverTabs, self.tracker.frontWindow === w, self.instances[id] != nil else { self.takingOver.remove(id); return }
            guard w.watcher?.isFocusedMain(w) == true else { return self.takeOverLook(w, look: look + 1, flow: flow) }
            let t = w.target
            var flow = flow
            let began = CACurrentMediaTime()
            let reading = TabStripTakeover.read(pid: t.pid, window: w.element)
            let step = flow.step(reading)
            DragTrace.log(String(format: "takeover: look %d read in %.1f ms: %@ -> %@", look, (CACurrentMediaTime() - began) * 1000,
                                 reading.summary, "\(step)"))
            switch step {
            case .press(let item):
                // An item that can't be pressed after all: nothing more for this window.
                guard TabStripTakeover.press(item, pid: t.pid) else { return self.finishTakeover(id) }
                DragTrace.log("takeover: pressed \(item) in \(t.bundleId)")
                self.takeOverLook(w, look: look + 1, flow: flow)
            case .pressBack(let item):
                let undone = TabStripTakeover.press(item, pid: t.pid)
                DragTrace.log("takeover: \(item) did not show in \(t.bundleId); pressed back \(undone), left alone from now")
                self.takeoverGaveUp.insert(t.bundleId)
                self.finishTakeover(id)
            case .lookAgain:
                self.takeOverLook(w, look: look + 1, flow: flow)
            case .done:
                self.finishTakeover(id) // as wanted, or can't be told
            case .undecided:
                self.takingOver.remove(id) // not written off: its next time in front looks again
            }
        }
    }

    private func finishTakeover(_ id: Int) {
        takenOver.insert(id)
        takingOver.remove(id)
    }
}
