import AppKit
import BetterlinkCore
import Foundation
import TabSyncCore
import Testing
@testable import Betterlink

// The sidebar's four rules (Nick, 2026-11-26), checked end to end:
//
// 1. The browser's width while its sidebar is closed is where it starts.
// 2. Open, sidebar width + browser width == that width: the pair occupies the
//    window's old frame, its far edge where it was, wherever the window is.
// 3. While open, the person may move or resize the browser or the sidebar
//    any way they like; at closing, browser + sidebar is the ending width.
// 4. Closed, the browser has the ending width: it takes the pair's frame.
//
// And the browser never ends further off its screen than it was.

/// A seeded generator (SplitMix64): the same seed gives the same cases on every run.
struct GuardRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    mutating func double(_ r: ClosedRange<Double>) -> Double { r.lowerBound + (r.upperBound - r.lowerBound) * Double(next() >> 11) / Double(1 << 53) }
    mutating func bool(_ p: Double = 0.5) -> Bool { double(0...1) < p }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(0...(xs.count - 1))] }
}

/// What a browser does with what it is asked through Accessibility.
struct BrowserBehaviour: CustomStringConvertible {
    enum Timing: String { case atOnce = "at once", late, busy }
    var timing: Timing = .atOnce
    /// Late or busy: by how long (seconds) it does what it was asked.
    var lateBy: Double = 0.3
    /// Stops there (macOS and the browser keep a window at least this wide).
    var minWidth: CGFloat = 0
    /// Takes any size, then widens itself back to `minWidth` when it answers.
    var widensBack = false
    /// Applies the position, never the size.
    var positionOnly = false
    /// Reports the asked size on this many reads, then its real one: the
    /// size never changes (Nick's Brave on 0.3.18).
    var revertReads = 0
    /// Drops the n-th size change it is given, once.
    var dropsSizeCall: Int?
    /// A tiling app puts the window back on its frame once, after the sidebar changed it.
    var tiler = false
    /// macOS 27 (Nick's laptop, 27.2.1, measured): each set is animated over
    /// this many seconds (easing in and out); a read gives the target at once,
    /// the window server the frame on screen, and the next set cuts the one in
    /// flight where it has got to. 0: at once.
    var animation: Double = 0
    /// Another reading of macOS 27: a size is taken only after this many
    /// reads (a frame or more); a size or a position sent meanwhile drops it,
    /// and a position is taken at once.
    var sizeLag = 0
    /// Stops answering now and then (its main thread busy for 100 to 300 ms):
    /// for `stall` calls in every `stall + every`, reads time out (or, with
    /// `staleReads`, give the frame from before), and what it is asked waits,
    /// then is done in order.
    var stall = 0, every = 0
    var staleReads = false

    /// Sizes it is given end up taken (late, once dropped, or after a tiling app, included).
    var sizesStick: Bool { !positionOnly && revertReads == 0 }

    var description: String {
        var s = [timing == .atOnce ? timing.rawValue : "\(timing.rawValue) by \(Int(lateBy * 1000)) ms"]
        if minWidth > 0 { s.append("minimum \(Int(minWidth))\(widensBack ? " (widens back to it)" : "")") }
        if positionOnly { s.append("applies the position, not the size") }
        if revertReads > 0 { s.append("reads back the asked size \(revertReads)x, then reverts") }
        if let n = dropsSizeCall { s.append("drops size change #\(n)") }
        if tiler { s.append("a tiling app puts it back once") }
        if animation > 0 { s.append("macOS 27: each set animated over \(Int(animation * 1000)) ms, cut short by the next") }
        if sizeLag > 0 { s.append("macOS 27: a size lands \(sizeLag) reads later, dropped by anything sent meanwhile") }
        if stall > 0 { s.append("stops answering for \(stall) calls in every \(stall + every)\(staleReads ? ", reading stale" : "")") }
        return s.joined(separator: ", ")
    }

    static func random(_ r: inout GuardRandom) -> BrowserBehaviour {
        var b = BrowserBehaviour()
        b.timing = r.pick([.atOnce, .atOnce, .late, .busy])
        b.lateBy = r.double(0.02...0.5)
        if b.timing == .atOnce, r.bool(0.3) { b.sizeLag = r.int(1...4) }
        if b.timing == .atOnce, b.sizeLag == 0, r.bool(0.35) { b.animation = r.double(0.05...0.35) }
        switch r.int(0...9) {
        case 0: b.positionOnly = true
        case 1: b.revertReads = r.int(1...6)
        default: break
        }
        if r.bool(0.4) { b.minWidth = CGFloat(r.int(300...1400)); b.widensBack = r.bool(0.25) }
        if r.bool(0.15) { b.dropsSizeCall = r.int(1...8) }
        if r.bool(0.15) { b.tiler = true }
        if b.timing == .atOnce, r.bool(0.25) { b.stall = r.int(2...12); b.every = r.int(1...8); b.staleReads = r.bool() }
        return b
    }
}

/// A browser window as macOS and a browser treat the sidebar's requests:
/// position and size are separate calls in Accessibility's coordinates, and
/// macOS limits each size to what fits on the display the window is on at
/// that moment. A move is not limited.
@MainActor
final class FakeBrowser: WindowHandle {
    /// The frame on screen now (mid-animation: where the animation has got to).
    var frame: CGRect {
        guard let a = anim else { return base }
        let u = behaviour.animation > 0 ? (now() - a.start) / behaviour.animation : 1
        if u >= 1 { base = a.to; anim = nil; return base }
        let f = CGFloat(u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2)
        return CGRect(x: a.from.minX + (a.to.minX - a.from.minX) * f, y: a.from.minY + (a.to.minY - a.from.minY) * f,
                      width: a.from.width + (a.to.width - a.from.width) * f, height: a.from.height + (a.to.height - a.from.height) * f)
    }
    private var base: CGRect
    private var anim: (from: CGRect, to: CGRect, start: Double)?
    /// The rig's clock, for animations.
    var now: () -> Double = { 0 }
    /// What a read gives: the target of an animation at once.
    private var readFrame: CGRect { anim?.to ?? frame }
    let behaviour: BrowserBehaviour
    var onScreen = true
    /// Every frame it has had, in order, and whether the person put it there.
    private(set) var history: [(frame: CGRect, byPerson: Bool)]
    private var queued: [(size: CGSize?, position: CGPoint?)] = []
    private var queuedAt = 0.0

    /// A late or busy browser gets to what it was asked once `lateBy` has passed.
    private func due() {
        guard behaviour.timing != .atOnce, !queued.isEmpty, now() - queuedAt >= behaviour.lateBy else { return }
        let todo = queued
        queued = []
        for q in todo {
            if let s = q.size { apply(s) }
            if let p = q.position { move(to: p) }
        }
    }

    private func enqueue(_ q: (size: CGSize?, position: CGPoint?)) {
        if queued.isEmpty { queuedAt = now() }
        queued.append(q)
    }
    private var sizeCalls = 0
    private var reported: CGSize?
    private var reportReads = 0
    private var tilerHome: CGRect?

    init(frame: CGRect, behaviour: BrowserBehaviour) {
        base = frame
        self.behaviour = behaviour
        history = [(frame, true)]
        if behaviour.tiler { tilerHome = frame }
    }

    private var height: CGFloat { Displays.primaryHeight! }
    private var busy: Bool { behaviour.timing == .busy && !queued.isEmpty }

    /// Calls so far, for a browser that stalls; the frame from before the stall began.
    private var calls = 0
    private var beforeStall: CGRect?
    /// Whether this call finds it stalled. Coming out of a stall, it does what waited.
    /// Set by the rig while a slide runs: the coordinator's run paused Brave during slides.
    var sliding = false {
        didSet { if !sliding, beforeStall != nil { beforeStall = nil; catchUp() } }
    }

    private func stalled() -> Bool {
        guard behaviour.stall > 0, sliding else { return false }
        calls += 1
        let inStall = calls % (behaviour.stall + behaviour.every) < behaviour.stall
        if inStall, beforeStall == nil { beforeStall = frame }
        if !inStall, beforeStall != nil { beforeStall = nil; catchUp() }
        return inStall
    }

    private func catchUp() {
        let todo = queued
        queued = []
        for q in todo {
            if let s = q.size { take(s) }
            if let p = q.position { move(to: p) }
        }
    }

    /// macOS 27: the size on its way, and how many reads until it lands.
    private var pendingSize: (size: CGSize, reads: Int)?

    private func tick() {
        guard var p = pendingSize else { return }
        p.reads -= 1
        if p.reads <= 0 { pendingSize = nil; take(p.size) } else { pendingSize = p }
    }

    func position() -> CGPoint? {
        tick()
        due()
        if stalled() { return behaviour.staleReads ? beforeStall.map { CGPoint(x: $0.minX, y: height - $0.maxY) } : nil }
        return busy ? nil : CGPoint(x: readFrame.minX, y: height - readFrame.maxY)
    }

    func size() -> CGSize? {
        tick()
        due()
        if stalled() { return behaviour.staleReads ? beforeStall?.size : nil }
        if busy { return nil }
        if reportReads > 0, let r = reported { reportReads -= 1; return r }
        return readFrame.size
    }

    func setPosition(_ p: CGPoint) {
        pendingSize = nil
        due()
        if behaviour.timing == .busy || stalled() { return enqueue((nil, p)) }
        move(to: p)
    }

    func setSize(_ s: CGSize) {
        pendingSize = nil
        due()
        if stalled() { return enqueue((s, nil)) }
        if behaviour.sizeLag > 0 { pendingSize = (s, behaviour.sizeLag); return }
        take(s)
    }

    private func take(_ s: CGSize) {
        sizeCalls += 1
        if sizeCalls == behaviour.dropsSizeCall { return }
        if behaviour.positionOnly { return }
        if behaviour.revertReads > 0 { reported = s; reportReads = behaviour.revertReads; return }
        switch behaviour.timing {
        case .atOnce: apply(s)
        case .late, .busy: enqueue((s, nil))
        }
    }

    func shownBounds() -> CGRect? {
        tick()
        due()
        return CGRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
    }

    var isOnScreen: Bool { onScreen }

    /// What it does once it gets to them: what it was asked, then its own
    /// minimum, then a tiling app's one put-back. True when the frame changed.
    @discardableResult
    func answer() -> Bool {
        let was = frame
        if let p = pendingSize { pendingSize = nil; take(p.size) }
        beforeStall = nil
        let todo = queued
        queued = []
        for q in todo {
            if let s = q.size { if behaviour.timing == .atOnce { take(s) } else { apply(s) } }
            if let p = q.position { move(to: p) }
        }
        if behaviour.widensBack, frame.width < behaviour.minWidth - 0.5 {
            set(CGRect(x: frame.minX, y: frame.minY, width: behaviour.minWidth, height: frame.height))
        }
        if let home = tilerHome, frame != home, history.contains(where: { !$0.byPerson }) {
            tilerHome = nil
            set(home)
        }
        return frame != was
    }

    /// The person moves or resizes the window.
    func person(_ f: CGRect) {
        queued = []
        pendingSize = nil
        reportReads = 0
        tilerHome = nil
        anim = nil
        base = f
        history.append((f, true))
    }

    private func move(to p: CGPoint) {
        let f = frame
        set(CGRect(x: p.x, y: height - p.y - f.height, width: f.width, height: f.height))
    }

    /// The top left stays; the size is limited to what fits on the display
    /// the window is on now, and to the browser's minimum.
    private func apply(_ s: CGSize) {
        let frame = self.frame
        // The displays side by side at its height count as one screen.
        let span = screenSpan(at: frame)
        let d = CGRect(x: span?.lowerBound ?? frame.minX, y: (Displays.all.max { $0.frame.intersection(frame).area < $1.frame.intersection(frame).area } ?? Displays.all[0]).frame.minY,
                       width: (span?.upperBound ?? frame.maxX) - (span?.lowerBound ?? frame.minX), height: 1)
        let least = behaviour.widensBack ? 1 : max(1, behaviour.minWidth)
        // A window can always go back where it has been, past the display's edge too.
        let reach = history.map(\.frame.maxX).max() ?? frame.maxX
        let w = max(least, min(s.width, max(max(d.maxX, frame.maxX, reach) - frame.minX, least)))
        let h = min(s.height, max(frame.maxY - d.minY, frame.height, 1))
        set(CGRect(x: frame.minX, y: frame.maxY - h, width: w, height: h))
    }

    /// Where it goes: at once, or (macOS 27) animated from where it is now,
    /// cutting short the animation in flight there.
    private func set(_ f: CGRect) {
        let at = frame
        if anim != nil { base = at; anim = nil; history.append((at, false)) }
        guard f != at else { return }
        if behaviour.animation > 0 { anim = (at, f, now()) } else { base = f }
        history.append((f, false))
    }
}

/// One sidebar on one fake browser window, driven through the app's own
/// show and hide: SidebarController.toggle, SidebarInstance's slide frame by
/// frame, the window read after each Accessibility event, and the window
/// tracker's settle once the window rests.
@MainActor
final class SidebarRig {
    let fake: FakeBrowser
    let window: TrackedWindow
    let instance: SidebarInstance
    let side: SidebarSide
    private let watcher: BrowserWatcher
    private var time: CFTimeInterval = 1000

    private static var nextNumber: CGWindowID = 4_000_000

    init(displays: [Display], frame: CGRect, side: SidebarSide, width: Double, behaviour: BrowserBehaviour, reduceMotion: Bool = false) {
        Displays.source = { displays }
        SidebarPanel.headless = true
        _ = NSApplication.shared
        let controller = SidebarController.shared
        if controller.side != side { controller.side = side }
        self.side = side
        fake = FakeBrowser(frame: frame, behaviour: behaviour)
        watcher = BrowserWatcher(.current, tracker: controller.tracker)
        Self.nextNumber += 1
        window = TrackedWindow(element: AXUIElementCreateApplication(getpid()), number: Self.nextNumber, watcher: watcher, handle: fake)
        window.read()
        instance = SidebarInstance(window: window, sidebar: controller, hidden: true, width: width)
        instance.clock = { [unowned self] in self.time }
        fake.now = { [unowned self] in self.time }
        instance.reducesMotion = { reduceMotion }
    }

    var open: Bool { !instance.hidden }
    var sidebarWidth: CGFloat { CGFloat(instance.width) }

    /// The shortcut: the slide to its end, then the window comes to rest.
    func toggle() {
        fake.sliding = true
        SidebarController.shared.toggle(instance)
        var frames = 0
        while instance.sliding, frames < 2000 {
            time += 1.0 / 120
            instance.stepSlide()
            events()
            frames += 1
        }
        fake.sliding = false
        rest()
    }

    /// Each move the browser makes is an Accessibility event: the window is
    /// read again and the panel follows it (SidebarController.changed).
    private func events() {
        watcher.refresh(window)
        instance.follow()
    }

    /// The browser answers what it was asked, a tiling app does its part, and
    /// the window tracker reports the window at rest, until nothing changes.
    /// The app's own look a moment later (`answerLater`), when nothing moved,
    /// is one more rest.
    func rest() {
        var quiet = 0
        for _ in 0..<16 {
            time += 0.5 // what is animating lands
            let changed = fake.answer()
            time += 0.5 // and what that started: the tracker reports rest only once the window stops moving
            events()
            instance.settle(window.target)
            var ticks = 0
            while instance.sliding, ticks < 2000 { // the app's own moves, tick by tick
                time += 1.0 / 120
                instance.stepSlide()
                events()
                ticks += 1
            }
            quiet = changed ? 0 : quiet + 1
            if quiet == 4 { break }
        }
    }

    /// The person moves or resizes the browser.
    func personSets(_ f: CGRect) {
        fake.person(f)
        events()
        rest()
    }

    /// The person drags the edge between the sidebar and the browser.
    func personDragsEdge(by delta: CGFloat) {
        guard instance.beginResize() else { return }
        instance.resize(by: delta)
        events()
        instance.endResize()
        rest()
    }

    /// The person (or a window-snapping tool) moves the sidebar itself by `dx`.
    func personMovesSidebar(by dx: CGFloat) {
        guard let panel = instance.panel else { return }
        panel.setFrameOrigin(CGPoint(x: panel.frame.minX + dx, y: panel.frame.minY))
        instance.movePairToPanel()
        events()
        rest()
    }

    /// The browser and its sidebar.
    var pair: CGRect {
        var p = fake.frame
        if open { p.size.width += sidebarWidth; if side == .left { p.origin.x -= sidebarWidth } }
        return p
    }

    /// The sidebar's outer edge (the one away from the browser), from the panel.
    var sidebarOuterEdge: CGFloat? {
        guard let p = instance.panel, p.isVisible else { return nil }
        return side == .left ? p.frame.minX : p.frame.maxX
    }
}

/// How far a frame runs past the displays beside it, in points (its
/// horizontal span not over any display at its height).
@MainActor
func offScreen(_ f: CGRect, _ displays: [Display]) -> CGFloat {
    let spans = displays.filter { $0.frame.minY < f.maxY - 1 && $0.frame.maxY > f.minY + 1 }
        .map { ($0.frame.minX, $0.frame.maxX) }.sorted { $0.0 < $1.0 }
    var covered: CGFloat = 0, reach = -CGFloat.infinity
    for (a, b) in spans {
        let lo = max(a, f.minX, reach), hi = min(b, f.maxX)
        if hi > lo { covered += hi - lo }
        reach = max(reach, b)
    }
    return max(0, f.width - covered)
}

/// The horizontal span of the display under most of `r` and the displays
/// side by side with it at `r`'s height: one screen, to a window.
@MainActor
func screenSpan(at r: CGRect) -> ClosedRange<CGFloat>? {
    let level = Displays.all.map(\.frame).filter { $0.minY < r.maxY - 1 && $0.maxY > r.minY + 1 }.sorted { $0.minX < $1.minX }
    guard let home = level.max(by: { $0.intersection(r).area < $1.intersection(r).area }) else { return nil }
    var lo = home.minX, hi = home.maxX
    for d in level where d.minX <= hi + 1 && d.maxX > hi { hi = d.maxX }
    for d in level.reversed() where d.maxX >= lo - 1 && d.minX < lo { lo = d.minX }
    return lo...hi
}

/// The frame the browser takes when the sidebar hides (rule 4): the pair's,
/// moved as little as it takes to be on the displays beside each other at
/// its height: the browser never ends off screen. No wider than they are.
@MainActor
func pairFrame(browser b: CGRect, sidebar w: CGFloat, side: SidebarSide) -> CGRect {
    var p = b
    p.size.width += w
    if side == .left { p.origin.x -= w }
    guard let span = screenSpan(at: p) else { return p }
    let lo = span.lowerBound, hi = span.upperBound
    p.size.width = min(p.width, hi - lo) // no window wider than its displays
    if p.maxX > hi { p.origin.x = hi - p.width }
    if p.minX < lo { p.origin.x = lo }
    return p
}

/// The checks after each step. Collects what failed, with the case.
@MainActor
struct RuleCheck {
    let rig: SidebarRig
    let displays: [Display]
    var problems: [String] = []
    private var mark = 0

    init(_ rig: SidebarRig, displays: [Display]) {
        self.rig = rig
        self.displays = displays
        mark = rig.fake.history.count
    }

    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 2 }
    private static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        near(a.minX, b.minX) && near(a.minY, b.minY) && near(a.width, b.width) && near(a.height, b.height)
    }

    /// Never further off screen than before the step, at rest and (for a
    /// browser that neither replays a backlog nor widens itself) at every moment.
    private mutating func noFurtherOff(than before: CGRect, _ step: String) {
        let allowed = offScreen(before, displays) + 2
        let b = rig.fake.behaviour
        let frames = rig.fake.history[mark...].filter { !$0.byPerson }.map(\.frame)
        // Replays (a busy or stalled browser doing late what it was asked, in a burst) and a browser
        // widening itself are checked at rest.
        let checked = (b.timing == .busy || b.widensBack || b.stall > 0) ? [rig.fake.frame] : frames + [rig.fake.frame]
        if let off = checked.first(where: { offScreen($0, displays) > allowed }) {
            problems.append("\(step): pushed off screen to \(off) (\(Int(offScreen(off, displays))) pt off; was \(before), \(Int(allowed - 2)) pt off)")
        }
        mark = rig.fake.history.count
    }

    /// The sidebar sits against the browser's edge, its width out.
    private mutating func besideTheBrowser(_ step: String) {
        guard rig.open, let outer = rig.sidebarOuterEdge else { return }
        let b = rig.fake.frame
        let want = rig.side == .left ? b.minX - rig.sidebarWidth : b.maxX + rig.sidebarWidth
        if !Self.near(outer, want) { problems.append("\(step): sidebar's outer edge at \(outer), wanted \(want) beside \(b), sidebar \(rig.sidebarWidth)") }
    }

    /// Rule 2 after showing from `start`; or, when it can't open, the window
    /// as it was. `mustOpen`: the browser can give the sidebar its least width.
    mutating func shown(from start: CGRect, mustOpen: Bool, _ step: String) {
        let b = rig.fake.frame
        if rig.open {
            let far = rig.side == .left ? (b.maxX, start.maxX) : (b.minX, start.minX)
            if !Self.near(b.width + rig.sidebarWidth, start.width) {
                problems.append("\(step): browser \(b.width) + sidebar \(rig.sidebarWidth) = \(b.width + rig.sidebarWidth), wanted \(start.width) (window \(b), was \(start))")
            }
            if !Self.near(far.0, far.1) { problems.append("\(step): far edge moved from \(far.1) to \(far.0) (window \(b), was \(start))") }
            if !Self.near(b.minY, start.minY) || !Self.near(b.height, start.height) { problems.append("\(step): height changed: \(b), was \(start)") }
            if let outer = rig.sidebarOuterEdge {
                let want = rig.side == .left ? start.minX : start.maxX
                if !Self.near(outer, want) { problems.append("\(step): sidebar's outer edge at \(outer), wanted the window's old edge \(want)") }
            } else {
                problems.append("\(step): open, but no panel on screen")
            }
            if rig.sidebarWidth < SidebarGeometry.widths.lowerBound - 0.5 { problems.append("\(step): sidebar \(rig.sidebarWidth) below its least width") }
        } else {
            if !Self.same(b, start) { problems.append("\(step): didn't open, but the window is at \(b), was \(start)") }
            if mustOpen { problems.append("\(step): didn't open, though the browser could make room (window \(start))") }
        }
        besideTheBrowser(step)
        noFurtherOff(than: start, step)
    }

    /// Rule 3: the person's move or resize stands.
    mutating func personDid(_ f: CGRect, _ step: String) {
        if !Self.same(rig.fake.frame, f) { problems.append("\(step): the person put the window at \(f), it is at \(rig.fake.frame)") }
        besideTheBrowser(step)
        mark = rig.fake.history.count
    }

    /// After the sidebar's edge was dragged: beside the browser, and the pair
    /// (the drag keeps its outer edges) no further off screen than it was.
    mutating func adjusted(from pair: CGRect, _ step: String) {
        besideTheBrowser(step)
        let allowed = offScreen(pair, displays) + 2
        if offScreen(rig.pair, displays) > allowed {
            problems.append("\(step): the pair pushed off screen to \(rig.pair) (was \(pair))")
        }
        mark = rig.fake.history.count
    }

    /// After the person moved the sidebar by `dx`: the browser went along, as one window.
    mutating func carried(from before: CGRect, by dx: CGFloat, _ step: String) {
        let want = before.offsetBy(dx: dx, dy: 0)
        if !Self.same(rig.fake.frame, want) { problems.append("\(step): the browser is at \(rig.fake.frame), wanted it carried to \(want)") }
        besideTheBrowser(step)
        mark = rig.fake.history.count
    }

    /// Rule 4: the browser takes the pair's frame.
    mutating func hidden(from b: CGRect, sidebar w: CGFloat, wasOpen: Bool, _ step: String) {
        let want = wasOpen ? pairFrame(browser: b, sidebar: w, side: rig.side) : b
        if rig.open { problems.append("\(step): still open") }
        if !Self.same(rig.fake.frame, want) {
            problems.append("\(step): hidden, the window is at \(rig.fake.frame), wanted the pair's frame \(want) (browser \(b) + sidebar \(w))")
        }
        noFurtherOff(than: b, step)
    }
}

// MARK: - Random cases

@MainActor
struct GuardCase: CustomStringConvertible {
    var displays: [Display]
    var window: CGRect
    var side: SidebarSide
    var width: Double
    var behaviour: BrowserBehaviour
    var reduceMotion: Bool
    /// What the person does while it is open, before each hide.
    var actions: [[Action]]

    enum Action: CustomStringConvertible {
        case moveBrowser(dx: CGFloat, dy: CGFloat)
        case resizeBrowser(left: CGFloat, right: CGFloat)
        case dragEdge(CGFloat)
        case moveSidebar(CGFloat)
        var description: String {
            switch self {
            case .moveBrowser(let dx, let dy): "moves the browser by \(Int(dx)), \(Int(dy))"
            case .resizeBrowser(let l, let r): "resizes the browser, left edge \(Int(l)), right edge \(Int(r))"
            case .dragEdge(let d): "drags the sidebar's edge \(Int(d))"
            case .moveSidebar(let dx): "moves the sidebar by \(Int(dx))"
            }
        }
    }

    var description: String {
        let ds = displays.map { "\($0.frame) visible \($0.visibleFrame) @\(Int($0.scale))x" }.joined(separator: "; ")
        return "displays [\(ds)], window \(window), sidebar \(side) \(Int(width)), browser \(behaviour)\(reduceMotion ? ", Reduce Motion" : ""), "
            + "the person: \(actions.map { $0.map(\.description).joined(separator: ", ") })"
    }

    /// A display: any size and scale, a menu bar 24 to 39 pt, the Dock on
    /// any side or hidden (an autohidden Dock still keeps 4 pt).
    static func display(_ r: inout GuardRandom, at origin: CGPoint, size: CGSize, menuBar: Bool) -> Display {
        let f = CGRect(origin: origin, size: size)
        var v = f
        if menuBar { v.size.height -= CGFloat(r.int(24...39)) }
        let dock = r.bool(0.3) ? 4 : CGFloat(r.int(40...100))
        switch r.int(0...3) {
        case 0: v.origin.y += dock; v.size.height -= dock
        case 1: v.origin.x += dock; v.size.width -= dock
        case 2: v.size.width -= dock
        default: break // no Dock on this display
        }
        return Display(frame: f, visibleFrame: v, scale: r.bool() ? 2 : 1)
    }

    static func random(_ r: inout GuardRandom) -> GuardCase {
        let size = { (r: inout GuardRandom) in CGSize(width: CGFloat(r.int(1024...3008)), height: CGFloat(r.int(640...1800))) }
        let main = display(&r, at: .zero, size: size(&r), menuBar: true)
        var displays = [main]
        if r.bool(0.45) {
            let s = size(&r)
            let m = main.frame
            let along = { (r: inout GuardRandom, a: CGFloat, b: CGFloat) in CGFloat(r.int(Int(-b + 100)...Int(a - 100))) }
            let origin: CGPoint
            switch r.int(0...3) {
            case 0: origin = CGPoint(x: m.maxX, y: along(&r, m.height, s.height))
            case 1: origin = CGPoint(x: -s.width, y: along(&r, m.height, s.height))
            case 2: origin = CGPoint(x: along(&r, m.width, s.width), y: m.maxY)
            default: origin = CGPoint(x: along(&r, m.width, s.width), y: -s.height)
            }
            displays.append(display(&r, at: origin, size: s, menuBar: r.bool(0.7)))
        }
        let d = r.pick(displays)
        let v = d.visibleFrame
        var w: CGRect
        switch r.int(0...7) {
        case 0: w = v // filled
        case 1: w = CGRect(x: d.frame.minX, y: d.frame.minY, width: d.frame.width, height: v.maxY - d.frame.minY) // down over the Dock
        case 2: w = CGRect(x: v.minX, y: v.minY, width: (v.width / 2).rounded(), height: v.height)
        case 3: w = CGRect(x: v.minX + (v.width / 2).rounded(), y: v.minY, width: v.width - (v.width / 2).rounded(), height: v.height)
        case 4:
            let n = CGFloat(r.pick([3, 4]))
            let i = CGFloat(r.int(0...(Int(n) - 1)))
            w = CGRect(x: v.minX + (v.width * i / n).rounded(), y: v.minY, width: (v.width / n).rounded(), height: v.height)
        case 5: // partly off screen
            let width = CGFloat(r.int(400...Int(max(401, v.width))))
            let out = width * CGFloat(r.double(0.05...0.4))
            w = CGRect(x: r.bool() ? d.frame.minX - out : d.frame.maxX - width + out, y: v.minY + CGFloat(r.int(0...40)),
                       width: width, height: max(200, v.height - CGFloat(r.int(0...200))))
        default: // anywhere, any size
            let width = CGFloat(r.int(120...Int(max(121, v.width))))
            let height = CGFloat(r.int(200...Int(max(201, v.height))))
            w = CGRect(x: v.minX + CGFloat(r.int(0...Int(max(0, v.width - width)))), y: v.minY + CGFloat(r.int(0...Int(max(0, v.height - height)))),
                       width: width, height: height)
        }
        w = w.integral
        var actions: [[Action]] = []
        for _ in 0..<2 {
            var round: [Action] = []
            for _ in 0..<r.int(0...3) {
                switch r.int(0...3) {
                case 0: round.append(.moveBrowser(dx: CGFloat(r.int(-300...300)), dy: CGFloat(r.int(-80...80))))
                case 1: round.append(.resizeBrowser(left: CGFloat(r.int(-150...150)), right: CGFloat(r.int(-150...150))))
                case 2: round.append(.dragEdge(CGFloat(r.int(-160...160))))
                // At least 5 pt: within 2 pt the app takes a frame for its own placement, rounded.
                default: round.append(.moveSidebar(CGFloat(r.int(5...200) * (r.bool() ? 1 : -1))))
                }
            }
            actions.append(round)
        }
        var b = BrowserBehaviour.random(&r)
        b.minWidth = min(b.minWidth, w.width) // a window is never narrower than its browser lets it be
        if b.timing != .atOnce || b.widensBack || b.animation > 0 || b.sizeLag > 0 {
            // A browser that has stopped answering is left alone by a drag of the edge (BrowserWatcher.isStalled),
            // which the fake can't make it; and one that answers (or widens itself back) after the drag has ended has been resized
            // as by hand, which is not put back (docs/tabs.md, Width). Nor macOS 27's animated sets: a drag of the
            // edge still asks the browser at each move of the pointer (not yet one call at a time). No drags for them.
            actions = actions.map { $0.filter { if case .dragEdge = $0 { false } else { true } } }
        }
        return GuardCase(displays: displays, window: w, side: r.bool() ? .left : .right, width: Double(r.int(200...440)),
                         behaviour: b, reduceMotion: r.bool(0.15), actions: actions)
    }

    /// Whether the browser can give the sidebar its least width out of `frame`.
    func canOpen(from frame: CGRect) -> Bool {
        behaviour.sizesStick && max(behaviour.minWidth, frame.width - width, 1) <= frame.width - SidebarGeometry.widths.lowerBound
    }

    /// Show, what the person does, hide; twice. The problems found, each with its step.
    func run() -> [String] {
        let rig = SidebarRig(displays: displays, frame: window, side: side, width: width, behaviour: behaviour, reduceMotion: reduceMotion)
        var check = RuleCheck(rig, displays: displays)
        for (round, todo) in actions.enumerated() {
            let start = rig.fake.frame
            rig.toggle()
            check.shown(from: start, mustOpen: canOpen(from: start), "show \(round + 1)")
            if rig.open {
                for (i, a) in todo.enumerated() {
                    let step = "show \(round + 1), the person \(a) (\(i + 1))"
                    let before = rig.fake.frame
                    switch a {
                    case .moveBrowser(let dx, let dy):
                        let f = before.offsetBy(dx: dx, dy: dy)
                        rig.personSets(f)
                        check.personDid(f, step)
                    case .resizeBrowser(let l, let r):
                        // macOS stops a resize by hand at the browser's own minimum.
                        var f = before
                        f.origin.x += l
                        f.size.width = max(200, behaviour.minWidth, f.width - l + r)
                        rig.personSets(f)
                        check.personDid(f, step)
                    case .dragEdge(let delta):
                        let pair = rig.pair
                        rig.personDragsEdge(by: delta)
                        check.adjusted(from: pair, step)
                    case .moveSidebar(let dx):
                        rig.personMovesSidebar(by: dx)
                        check.carried(from: before, by: dx, step)
                    }
                }
            }
            let wasOpen = rig.open
            let b = rig.fake.frame, w = rig.sidebarWidth
            if wasOpen { rig.toggle() }
            check.hidden(from: b, sidebar: w, wasOpen: wasOpen, "hide \(round + 1)")
            if !check.problems.isEmpty { break }
        }
        return check.problems
    }
}

/// The sidebar's show and hide, end to end, against fake browser windows on
/// fake displays (see the four rules above). PR 72's tests checked the
/// geometry and the loan as pure functions; these drive the code that moves
/// the window, as the shortcut does.
@MainActor @Suite(.serialized) struct SidebarGuardTests {
    init() throws {
        let home = TestHome.folder
        try #require(SettingsFolder.resolve().directory.path == home.path)
        try #require(MenuBarIcon.defaults() !== UserDefaults.standard)
    }

    // MARK: Random cases

    /// `BETTERLINK_GUARD_SEED` and `BETTERLINK_GUARD_CASES` override the seed
    /// and the count; a failure prints the seed and the case to rerun it.
    @Test func everyCaseKeepsTheFourRules() {
        let env = ProcessInfo.processInfo.environment
        let seed = env["BETTERLINK_GUARD_SEED"].flatMap { UInt64($0) } ?? 0x5EED_92
        let count = env["BETTERLINK_GUARD_CASES"].flatMap { Int($0) } ?? 2000
        var failed: [(Int, GuardCase, [String])] = []
        for i in 0..<count {
            var r = GuardRandom(seed: seed &+ UInt64(i) &* 0x9E37_79B9)
            let c = GuardCase.random(&r)
            let problems = c.run()
            if !problems.isEmpty { failed.append((i, c, problems)) }
        }
        print("SidebarGuard: \(count) random cases from seed \(seed), \(failed.count) failed")
        // BETTERLINK_GUARD_LIST=1: each failed case's first problem, one line each.
        if env["BETTERLINK_GUARD_LIST"] == "1" {
            for (i, c, problems) in failed { print("SidebarGuard case \(i): \(problems[0]) || \(c.behaviour) || \(c.side) \(Int(c.width)) window \(c.window)") }
        }
        for (i, c, problems) in failed.prefix(12) {
            let found = problems.prefix(3).joined(separator: "\n  ")
            Issue.record("case \(i) of seed \(seed): \(c)\n  \(found)")
        }
        #expect(failed.isEmpty, "\(failed.count) of \(count) random cases broke a rule (seed \(seed))")
    }

    // MARK: Named cases

    private func run(_ c: GuardCase, sourceLocation: SourceLocation = #_sourceLocation) {
        let problems = c.run()
        #expect(problems.isEmpty, "\(c)\n  \(problems.joined(separator: "\n  "))", sourceLocation: sourceLocation)
    }

    /// Nick's laptop on 0.3.18: 2056 x 1329 points, a 39 pt menu bar, Brave
    /// filling the screen below it (0, 39 to 2056, 1329 in AppleScript's
    /// bounds), the sidebar on the left at 280. Showing moved it 280 right
    /// without narrowing it, and hiding gave nothing back: the move applied,
    /// the size didn't stick, though reading it back said it had.
    @Test func nicksLaptopBrave() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        let brave = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        var behaviours = [BrowserBehaviour(revertReads: 2), BrowserBehaviour(revertReads: 6), BrowserBehaviour(positionOnly: true),
                          BrowserBehaviour(minWidth: 615), BrowserBehaviour(sizeLag: 1), BrowserBehaviour(sizeLag: 2), BrowserBehaviour(sizeLag: 4),
                          BrowserBehaviour(animation: 0.2), BrowserBehaviour(animation: 0.25), BrowserBehaviour(animation: 0.3)]
        behaviours.append(BrowserBehaviour(timing: .late, minWidth: 615))
        for b in behaviours {
            run(GuardCase(displays: [screen], window: brave, side: .left, width: 280, behaviour: b, reduceMotion: false, actions: [[], []]))
        }
    }

    /// Nick's three measurements on macOS 27.2.1 (Brave at 0, 39 to 2056,
    /// 1329, AppleScript's bounds; each asked for 280, 39 to 2056, 1329), as
    /// the fake browser has them: each set animated over 0.25 s and cut short
    /// by the next. The timings are those his calls took.
    @Test func nicksMacOS27Measurements() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        Displays.source = { [screen] }
        let brave = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        // A: size; read it (it says 1776 at once); position. 1871 wide.
        var t = 0.0
        let a = FakeBrowser(frame: brave, behaviour: BrowserBehaviour(animation: 0.25))
        a.now = { t }
        a.setSize(CGSize(width: 1776, height: 1290))
        #expect(a.size()?.width == 1776)
        t += 0.140
        a.setPosition(CGPoint(x: 280, y: 39))
        t += 10
        #expect(abs(a.frame.width - 1871) < 3 && a.frame.minX == 280, "A: \(a.frame)")
        // B: position, then size. At x 15.
        t = 0
        let b = FakeBrowser(frame: brave, behaviour: BrowserBehaviour(animation: 0.25))
        b.now = { t }
        b.setPosition(CGPoint(x: 280, y: 39))
        t += 0.0594
        b.setSize(CGSize(width: 1776, height: 1290))
        t += 10
        #expect(abs(b.frame.minX - 15) < 3 && b.frame.width == 1776, "B: \(b.frame)")
        // C: sixteen steps 15 ms apart, each size then position. 1838 wide.
        t = 0
        let c = FakeBrowser(frame: brave, behaviour: BrowserBehaviour(animation: 0.25))
        c.now = { t }
        for i in 1...16 {
            let q = CGFloat(i) / 16
            c.setSize(CGSize(width: 2056 - 280 * q, height: 1290))
            t += 0.0947
            c.setPosition(CGPoint(x: 280 * q, y: 39))
            t += 0.015
        }
        t += 10
        #expect(abs(c.frame.width - 1838) < 3 && c.frame.minX == 280, "C: \(c.frame)")
    }

    /// PR 72's placements: a window filling the screen or snapped to a half,
    /// either side: narrowed by exactly the sidebar's width, given it all back.
    @Test func pr72Placements() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1259),
                             visibleFrame: CGRect(x: 0, y: 64, width: 2056, height: 1259 - 64 - 37), scale: 2)
        let v = screen.visibleFrame
        for w in [v, CGRect(x: 0, y: v.minY, width: 1028, height: v.height), CGRect(x: 1028, y: v.minY, width: 1028, height: v.height)] {
            for side in SidebarSide.allCases {
                let c = GuardCase(displays: [screen], window: w, side: side, width: 280, behaviour: .init(), reduceMotion: false, actions: [[], []])
                run(c)
                let rig = SidebarRig(displays: [screen], frame: w, side: side, width: 280, behaviour: .init())
                rig.toggle()
                var want = w
                want.size.width -= 280
                if side == .left { want.origin.x += 280 }
                #expect(GuardFrames.same(rig.fake.frame, want), "\(w) \(side): \(rig.fake.frame), wanted \(want)")
            }
        }
    }

    /// Brave (its least width 615 pt) snapped to the right half (864 pt) of a
    /// 1728 pt screen, the sidebar on the left: the browser can give 249, so
    /// the sidebar is 249 wide and the pair is the half.
    @Test func braveRightHalfAt615() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                             visibleFrame: CGRect(x: 0, y: 70, width: 1728, height: 1117 - 70 - 38), scale: 2)
        let half = CGRect(x: 864, y: 70, width: 864, height: 1009)
        for b in [BrowserBehaviour(minWidth: 615), BrowserBehaviour(minWidth: 615, widensBack: true), BrowserBehaviour(timing: .late, minWidth: 615)] {
            run(GuardCase(displays: [screen], window: half, side: .left, width: 280, behaviour: b, reduceMotion: false, actions: [[], []]))
            let rig = SidebarRig(displays: [screen], frame: half, side: .left, width: 280, behaviour: b)
            rig.toggle()
            #expect(GuardFrames.same(rig.fake.frame, CGRect(x: 1113, y: 70, width: 615, height: 1009)), "\(b): \(rig.fake.frame)")
            #expect(abs(rig.sidebarWidth - 249) < 2, "\(b): sidebar \(rig.sidebarWidth)")
        }
    }
}

/// Frames within 2 pt count as the same: the browser rounds.
enum GuardFrames {
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
