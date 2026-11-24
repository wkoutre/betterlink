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

    @Published private(set) var trusted = WindowTracker.isTrusted
    /// The browser window the sidebar is bound to right now. Its `frame` is
    /// only as fresh as the last change of window or title, so a drag doesn't
    /// redraw the tab list; `current` has the live frame.
    @Published private(set) var target: WindowTracker.Target?
    @Published private(set) var placedSide: SidebarSide = .right

    private let tracker: WindowTracker
    private var panel: SidebarPanel?
    private var current: WindowTracker.Target?
    /// A window this sidebar resized, by window: the space the user gave the
    /// pair, and the frame the window took inside it.
    private struct Fit { var outer: CGRect, inner: CGRect, side: SidebarSide }
    private var fits: [Int: Fit] = [:]
    /// The narrowest a browser let its window get, by window, once it stopped us.
    private var minWidths: [Int: CGFloat] = [:]
    private var askedAt = Date.distantPast
    /// The frame a window would not give up, so it isn't asked again.
    private var refused: CGRect?
    private var trustToken: NSObjectProtocol?
    /// A separate domain while `BETTERLINK_HOME` is set, like the menu bar icon.
    private let defaults = MenuBarIcon.defaults()

    private init() {
        tracker = WindowTracker(browserBundleIds: Set(Browser.known.map(\.bundleId)))
        enabled = defaults.bool(forKey: "sidebar.enabled")
        side = SidebarSide(rawValue: defaults.string(forKey: "sidebar.side") ?? "") ?? .right
        let w = defaults.double(forKey: "sidebar.width")
        width = w >= 200 ? w : 280
        tracker.onChange = { [weak self] t in self?.targetChanged(t) }
        tracker.onSettle = { [weak self] t in self?.settle(t) }
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

    // MARK: - Lifecycle

    private func start() {
        trusted = WindowTracker.isTrusted
        guard trusted else { WindowTracker.requestTrust(); return }
        TabsModel.shared.start()
        tracker.start()
    }

    private func stop() {
        // Give the window back the space the sidebar took.
        if let t = current, let f = fits[t.windowHash], Self.same(t.frame, f.inner) { tracker.setWindowFrame(f.outer) }
        fits = [:]
        minWidths = [:]
        tracker.stop()
        panel?.orderOut(nil)
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
    }

    // MARK: - Layout

    private func targetChanged(_ t: WindowTracker.Target?) {
        current = t
        var shown = t
        if let old = target { shown?.frame = old.frame }
        if shown != target { target = t }
        layout()
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
        guard enabled, !t.fullScreen else { return }
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
                                     side: SidebarGeometry.resolve(side, window: outer, screen: screen))
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
        guard enabled, let t = current, !t.fullScreen else {
            panel?.orderOut(nil)
            return
        }
        let fit = fits[t.windowHash].flatMap { Self.same($0.inner, t.frame) ? $0 : nil }
        let p = SidebarGeometry.place(window: t.frame, screen: screen(for: t.frame), width: width, side: fit?.side ?? side,
                                      keepOnScreen: refused.map { Self.same($0, t.frame) } ?? false)
        if placedSide != p.side { placedSide = p.side }
        let panel = self.panel ?? makePanel()
        panel.attach(to: p.overlaps ? nil : p.side)
        // A pure move is cheap; only a real resize lays the tab list out again.
        if panel.frame.size == p.sidebar.size {
            panel.setFrameOrigin(p.sidebar.origin)
        } else {
            panel.setFrame(p.sidebar, display: true, animate: false)
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> SidebarPanel {
        let host = NSHostingView(rootView: SidebarView().environmentObject(self))
        // The browser window sets the panel's size; the content must never grow it.
        host.sizingOptions = []
        let panel = SidebarPanel(contentView: host)
        self.panel = panel
        return panel
    }

    // MARK: - Actions from the sidebar

    /// After a click or a typed link in the sidebar, hand the keyboard back to the browser.
    func returnFocusToBrowser() { tracker.activateBrowser() }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// A borderless, non-activating panel: clicking it never takes the browser out
/// of the front, but it can still take keyboard focus for its text field.
final class SidebarPanel: NSPanel {
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
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let effect = NSVisualEffectView()
        self.effect = effect
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.masksToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            content.topAnchor.constraint(equalTo: effect.topAnchor),
            content.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    private var effect: NSVisualEffectView?
    /// Close to the system's window corner radius.
    static let cornerRadius: CGFloat = 12

    /// Squares the corners on the side that touches the browser window, so the
    /// pair reads as one window with no gap at the seam; rounds the outer side.
    /// nil (the panel sits over the window's edge) rounds all four.
    func attach(to side: SidebarSide?) {
        guard let layer = effect?.layer else { return }
        switch side {
        case .right: layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        case .left: layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        default: layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
