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
        enabled = defaults.bool(forKey: "sidebar.enabled")
        side = SidebarSide(rawValue: defaults.string(forKey: "sidebar.side") ?? "") ?? .right
        memory = defaults.data(forKey: "sidebar.fitMemory").flatMap { try? JSONDecoder().decode(FitMemory.self, from: $0) } ?? FitMemory()
        memory.prune(alive: WindowTracker.liveWindowNumbers())
        let w = defaults.double(forKey: "sidebar.width")
        width = w >= 200 ? w : 280
        tracker.onChange = { [weak self] t in self?.targetChanged(t) }
        tracker.onSettle = { [weak self] t in self?.settle(t) }
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
        // Hiding gives every narrowed window its space back, not only the one in front (review F1).
        if !collapsed { giveSpaceBack() }
        collapsed.toggle()
        save()
        if !collapsed, let t = current { settle(t) }
        layout()
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
        // The tab list matches the window by its frame: refresh it now that it is still.
        if target != t { target = t }
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
        let ownAppInFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        guard enabled, !collapsed, let t = current, !t.fullScreen else {
            panel?.orderOut(nil)
            return
        }
        let fit = fits[t.windowHash].flatMap { Self.same($0.inner, t.frame) ? $0 : nil }
        let p = SidebarGeometry.place(window: t.frame, screen: screen(for: t.frame), width: width, side: fit?.side ?? side,
                                      keepOnScreen: refused.map { Self.same($0, t.frame) } ?? false)
        if placedSide != p.side { placedSide = p.side }
        let panel = self.panel ?? makePanel()
        let attached: SidebarSide? = p.overlaps ? nil : p.side
        panel.attach(to: attached)
        // Beside the window, the panel reaches under the window's rounded
        // corners to fill them (see SidebarPanel), so it is that much wider.
        let reach = attached == nil ? 0 : SidebarPanel.browserCornerRadius
        var frame = p.sidebar
        frame.size.width += reach
        if attached == .right { frame.origin.x -= reach }
        // A pure move is cheap; only a real resize lays the tab list out again.
        if panel.frame.size == frame.size {
            panel.setFrameOrigin(frame.origin)
        } else {
            panel.setFrame(frame, display: true, animate: false)
        }
        if ownAppInFront {
            // Beside the browser window, under betterlink's own windows; with
            // no window number to order against, hidden rather than on top.
            guard let n = tracker.boundWindowNumber else { panel.orderOut(nil); return }
            if panel.level != .normal { panel.level = .normal }
            panel.order(.above, relativeTo: Int(n))
        } else {
            if panel.level != .floating { panel.level = .floating }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }

    private func makePanel() -> SidebarPanel {
        let host = NSHostingView(rootView: SidebarView().environmentObject(self))
        // The browser window sets the panel's size; the content must never grow it.
        host.sizingOptions = []
        let panel = SidebarPanel(contentView: host)
        panel.setTint(tint)
        self.panel = panel
        return panel
    }

    // MARK: - Actions from the sidebar

    /// Paints the sidebar in the browser profile's frame color (nil: the
    /// standard sidebar material), so it reads as part of that window.
    func setTint(_ rgb: UInt32?) { tint = rgb; panel?.setTint(rgb) }
    private var tint: UInt32?

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
    func attach(to side: SidebarSide?) {
        self.side = side
        let r = side == nil ? 0 : Self.browserCornerRadius
        leading?.constant = side == .right ? r : 0
        trailing?.constant = side == .left ? -r : 0
        reshape()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        reshape()
    }

    /// The sidebar with rounded outer corners, plus the bits of the strip under
    /// the browser's edge that its rounded corners leave uncovered.
    private func reshape() {
        let b = effect.bounds
        guard b.width > 0, b.height > 0 else { return }
        let reach = Self.browserCornerRadius, c = Self.corner
        let path: CGPath
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
}
