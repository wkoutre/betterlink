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
    @Published var side: SidebarSide { didSet { save(); relayout(rebind: true) } }
    @Published var width: Double { didSet { save(); relayout(rebind: false) } }
    @Published var makeRoom: Bool { didSet { save(); relayout(rebind: true) } }

    @Published private(set) var trusted = WindowTracker.isTrusted
    /// The browser window the sidebar is bound to right now.
    @Published private(set) var target: WindowTracker.Target?
    @Published private(set) var placedSide: SidebarSide = .right

    private let tracker: WindowTracker
    private var panel: SidebarPanel?
    private var boundWindow: Int?
    private var trustToken: NSObjectProtocol?
    private let defaults = UserDefaults.standard

    private init() {
        tracker = WindowTracker(browserBundleIds: Set(Browser.known.map(\.bundleId)))
        enabled = defaults.bool(forKey: "sidebar.enabled")
        side = SidebarSide(rawValue: defaults.string(forKey: "sidebar.side") ?? "") ?? .right
        let w = defaults.double(forKey: "sidebar.width")
        width = w >= 200 ? w : 280
        makeRoom = defaults.bool(forKey: "sidebar.makeRoom")
        tracker.onChange = { [weak self] t in self?.targetChanged(t) }
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
        tracker.stop()
        panel?.orderOut(nil)
        boundWindow = nil
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
        defaults.set(makeRoom, forKey: "sidebar.makeRoom")
    }

    // MARK: - Layout

    private func targetChanged(_ t: WindowTracker.Target?) {
        target = t
        relayout(rebind: false)
    }

    private func relayout(rebind: Bool) {
        guard enabled, let t = target, !t.fullScreen else {
            panel?.orderOut(nil)
            return
        }
        if rebind { boundWindow = nil }
        let screen = (NSScreen.screens.max { a, b in
            a.frame.intersection(t.frame).area < b.frame.intersection(t.frame).area
        } ?? NSScreen.main)?.visibleFrame ?? t.frame
        let firstBind = boundWindow != t.windowHash
        boundWindow = t.windowHash
        // Make room only when binding to a window (or when a setting changes),
        // never while the user is moving or resizing it: that would fight them.
        let p = SidebarGeometry.place(window: t.frame, screen: screen, width: width, side: side,
                                      makeRoom: makeRoom && firstBind)
        // Resizing the window publishes its new frame, which lands here again;
        // the panel goes to its final spot now in case the browser refuses.
        if let newFrame = p.window { tracker.setWindowFrame(newFrame) }
        placedSide = p.side
        let panel = self.panel ?? makePanel()
        panel.setFrame(p.sidebar, display: true, animate: false)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() -> SidebarPanel {
        let panel = SidebarPanel(contentView: NSHostingView(rootView: SidebarView().environmentObject(self)))
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
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
