import AppKit
import BetterlinkCore
import TabSyncCore

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
        away()
    }

    /// Tests: ordered in and out without the window server, so no panel shows
    /// on the Mac that runs them (SidebarGuardTests). Everything else, its
    /// frame included, is the real panel's.
    static var headless = false
    private var headlessVisible = false

    override var isVisible: Bool { Self.headless ? headlessVisible : super.isVisible }

    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard Self.headless else { return super.order(place, relativeTo: otherWin) }
        headlessVisible = place != .out
    }

    /// Off the screen at once.
    private func away() {
        headlessVisible = false
        if !Self.headless { super.orderOut(nil) }
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
    /// How far the panel reaches under the browser window: the corner's curve.
    var reach: CGFloat { Self.browserCornerRadius }

    init(contentView content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 280, height: 600),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        // Among the other windows, next to its browser window, never floating
        // over them (SidebarPresence says where).
        level = .normal
        hidesOnDeactivate = false
        // Hiding betterlink's own window leaves the sidebars with their browsers.
        canHide = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        // No shadow of its own: it would fall across the browser along the seam,
        // and the pair should read as one window.
        hasShadow = false
        // Our slide and fade are the only motion; no system fade on close.
        animationBehavior = .none
        // On its browser window's Space, coming and going with it.
        collectionBehavior = [.managed, .fullScreenNone, .ignoresCycle]

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

    /// A place among the windows: next to a browser window, by its number.
    struct Place {
        var relation: SidebarPresence.Relation
        var window: UInt32
    }

    /// Puts the panel in its place, ordering it in when it isn't. Works while
    /// another app is in front.
    func order(at place: Place) {
        order(place.relation == .above ? .above : .below, relativeTo: Int(place.window))
    }

    /// Called after the mouse was pressed or released in the panel: macOS
    /// brings a pressed window in front of the others.
    var onClick: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp: onClick?()
        default: break
        }
    }

    /// Shows at full alpha at once (a slide reveals it instead of a fade).
    func showNow(at place: Place) {
        fadeTimer?.invalidate(); fadeTimer = nil
        fade = Fade(shown: true)
        alphaValue = 1
        order(at: place)
    }

    /// Out and in again at once. A key panel gives the keyboard back to the
    /// active app's window that way (it keeps it until it is ordered out), and
    /// a panel on another Space comes to the one showing.
    func reenter(at place: Place) {
        away()
        order(at: place)
    }

    /// Hides at once, at the end of a slide.
    func hideNow() {
        fadeTimer?.invalidate(); fadeTimer = nil
        away()
        fade = Fade(shown: false)
        alphaValue = 1
    }

    /// Shows the panel with a short fade (none with Reduce Motion).
    func fadeIn(at place: Place) {
        guard fade.phase == .hidden || fade.phase == .hiding || !isVisible else { return }
        if !isVisible { fade = Fade(shown: false); alphaValue = 0; order(at: place) }
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
            away()
            alphaValue = 1
        }
    }
}
