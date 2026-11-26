import AppKit
import BetterlinkCore
import TabSyncCore

/// A borderless, non-activating panel: clicking it never takes the browser out
/// of the front, but it can still take keyboard focus for its text field.
///
/// Beside a browser window it lies directly under the window and reaches
/// `overlap` under the window's edge, past the window's rounded corners
/// (SidebarSeam). The window draws its own corners over the sidebar, so what
/// they leave open is filled by the sidebar whatever their shape, and clicks
/// on the window's edge are the window's. Its two outer corners are a system
/// window's. Covering the window's edge instead (the window would not make
/// room), it lies on top of the window, rounded all round.
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

    /// The outer corners: those macOS gives a window of a browser's style.
    static let corner = ContinuousCorner.window
    /// How far a browser window's corner may run along its edge: as far as
    /// the largest corner macOS gives a window, since another app's window
    /// doesn't tell its own. The panel reaches at least that far under it.
    static let reach: CGFloat = {
        let reach = max(ContinuousCorner.largest.span, corner.span)
        DragTrace.log("corner: outer corners run \(corner.span) pt along the edge, the panel reaches \(reach) pt under its window")
        return reach
    }()

    private let effect = NSVisualEffectView()
    private let shape = CAShapeLayer()
    /// The profile color, under the content and inside the same mask.
    private let tint = NSView()
    private var leading: NSLayoutConstraint?
    private var trailing: NSLayoutConstraint?
    private var side: SidebarSide?
    /// How far the panel reaches under the browser window now. None while it
    /// covers the window's edge.
    private(set) var overlap: CGFloat = 0

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
        // No shadow of its own, as before it went under its window (it fell
        // across the browser along the seam then). The window's falls on it.
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

    /// Which side of the browser window the panel is on, reaching `overlap`
    /// under the window, or nil when it covers the window's edge instead.
    func attach(to side: SidebarSide?, overlap: CGFloat) {
        self.side = side
        self.overlap = side == nil ? 0 : overlap
        // The content keeps to the sidebar: none of it under the window.
        leading?.constant = side == .right ? self.overlap : 0
        trailing?.constant = side == .left ? -self.overlap : 0
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

    /// During a slide, the part of the panel shown: from `reveal` (screen x,
    /// SidebarSeam.reveal) to the outer edge. Nil: the whole panel.
    var reveal: CGFloat? { didSet { reshape() } }

    private func reshape() {
        let b = effect.bounds
        guard b.width > 0, b.height > 0 else { return }
        let path = Self.outline(in: b, side: side, reveal: reveal.map { $0 - frame.minX }, corner: Self.corner)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = b
        shape.path = path
        CATransaction.commit()
    }

    /// The panel's outline in its own bounds. Beside a window (`side`): all
    /// of it, the two outer corners rounded; the end under the window stays
    /// square, the window covers it. Covering a window's edge (nil): rounded
    /// all round. During a slide: only the strip from `reveal` (x in the
    /// bounds) to the outer edge; the content stays anchored and isn't
    /// reflowed.
    static func outline(in b: CGRect, side: SidebarSide?, reveal: CGFloat?, corner c: ContinuousCorner) -> CGPath {
        guard let side else { return c.rect(b, corners: [0, 1, 2, 3]) }
        let outer: Set<Int> = side == .left ? [0, 3] : [1, 2]
        guard let reveal else { return c.rect(b, corners: outer) }
        let x = min(max(reveal, 0), b.width)
        let strip = side == .left ? CGRect(x: 0, y: 0, width: x, height: b.height)
                                  : CGRect(x: x, y: 0, width: b.width - x, height: b.height)
        return strip.width < 1 ? CGMutablePath() : c.rect(strip, corners: outer)
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

    /// Where the panel was last put.
    private var home: Place?

    /// Puts the panel in its place, ordering it in when it isn't. Works while
    /// another app is in front.
    func order(at place: Place) {
        home = place
        super.order(place.relation == .above ? .above : .below, relativeTo: Int(place.window))
    }

    /// Asked to the front, a panel on screen goes to its place instead: in
    /// front of its window it would cover the window's edge.
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
        guard place == .above, otherWin == 0, isVisible, let home else { return super.order(place, relativeTo: otherWin) }
        DragTrace.log("order: asked to the front, kept in its place")
        super.order(home.relation == .above ? .above : .below, relativeTo: Int(home.window))
    }

    /// Called when the mouse is pressed or released in the panel: macOS
    /// brings a pressed window in front of the others.
    var onClick: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        let press: Bool
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp: press = true
        default: press = false
        }
        // A press that opens a menu stays in `super` until the menu closes:
        // the menu's own run loop calls back meanwhile.
        if press {
            RunLoop.main.perform(inModes: [.common]) { [weak self] in MainActor.assumeIsolated { self?.onClick?() } }
        }
        super.sendEvent(event)
        if press { onClick?() }
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
        super.orderOut(nil)
        order(at: place)
    }

    /// Hides at once, at the end of a slide.
    func hideNow() {
        fadeTimer?.invalidate(); fadeTimer = nil
        super.orderOut(nil)
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
            super.orderOut(nil)
            alphaValue = 1
        }
    }
}
