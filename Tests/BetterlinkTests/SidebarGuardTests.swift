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
        // Most answer within half a second; some (late) well after betterlink has stopped waiting
        // (2 x WindowSteps.timeout). A busy one, which doesn't answer reads either, is the browser
        // that has stopped answering for a moment: within half a second.
        let long = r.bool(0.3)
        b.lateBy = long && b.timing == .late ? r.double(0.5...3) : r.double(0.02...0.5)
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
    /// What it does with what it is asked; a test may change it once a sidebar is open.
    var behaviour: BrowserBehaviour
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

    /// It has been asked something it hasn't done yet (late, busy, or a size on its way).
    var hasQueued: Bool { !queued.isEmpty || pendingSize != nil }
    /// The last read of its position or size got no answer (busy or stalled).
    private(set) var lastReadFailed = false

    private func tick() {
        guard var p = pendingSize else { return }
        p.reads -= 1
        if p.reads <= 0 { pendingSize = nil; take(p.size) } else { pendingSize = p }
    }

    func position() -> CGPoint? {
        let p = readPosition()
        lastReadFailed = p == nil
        return p
    }

    private func readPosition() -> CGPoint? {
        tick()
        due()
        if stalled() { return behaviour.staleReads ? beforeStall.map { CGPoint(x: $0.minX, y: height - $0.maxY) } : nil }
        return busy ? nil : CGPoint(x: readFrame.minX, y: height - readFrame.maxY)
    }

    func size() -> CGSize? {
        let s = readSize()
        lastReadFailed = s == nil
        return s
    }

    private func readSize() -> CGSize? {
        tick()
        due()
        if stalled() { return behaviour.staleReads ? beforeStall?.size : nil }
        if busy { return nil }
        if reportReads > 0, let r = reported { reportReads -= 1; return r }
        return readFrame.size
    }

    /// Every size and position it has been sent, for the time bound.
    private(set) var setCalls = 0

    func setPosition(_ p: CGPoint) {
        setCalls += 1
        pendingSize = nil
        due()
        if behaviour.timing == .busy || stalled() { return enqueue((nil, p)) }
        move(to: p)
    }

    func setSize(_ s: CGSize) {
        setCalls += 1
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

    /// `hidden`: false for a window followed with its sidebar on, which
    /// opens when it is first followed (`follow(during:)`), not by a press.
    init(displays: [Display], frame: CGRect, side: SidebarSide, width: Double, behaviour: BrowserBehaviour, reduceMotion: Bool = false,
         hidden: Bool = true) {
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
        instance = SidebarInstance(window: window, sidebar: controller, hidden: hidden, width: width)
        instance.clock = { [unowned self] in self.time }
        // Quitting waits on the rig's clock, as everything else does.
        instance.pause = { [unowned self] in self.time += $0 }
        fake.now = { [unowned self] in self.time }
        instance.reducesMotion = { reduceMotion }
        SidebarRig.notices = []
        SidebarInstance.tell = { notice, frame in SidebarRig.notices.append((notice, frame)) }
    }

    /// The notes shown since the rig was made: why the sidebar didn't open, and over which frame.
    static var notices: [(SidebarNotice, CGRect)] = []


    /// betterlink quit, or let the window go (`During.quit`, `.turnOff`): no sidebar any more.
    private(set) var gone = false
    /// When it did, the browser wasn't answering: such a window keeps its
    /// record and is sent nothing (`SidebarInstance.spaceBack`), since each
    /// call to it would hold up quitting.
    private(set) var goneUnanswered = false
    var open: Bool { !gone && !instance.hidden }
    /// The rig's clock now.
    var now: Double { time }
    var sidebarWidth: CGFloat { CGFloat(instance.width) }

    /// What else happens while a press of the shortcut is carried out, a
    /// moment after it: the shortcut pressed again, or the person moving or
    /// resizing the browser (to the frame on screen then, its left edge by
    /// `left`, its right edge by `right`, its top by `dy`).
    enum During: CustomStringConvertible {
        case press
        case person(left: CGFloat, right: CGFloat, dy: CGFloat)
        /// betterlink quits: the window gets its space back at once (`giveSpaceBack`).
        case quit
        /// The sidebar is turned off, or the browser no longer attached: the window is let go (`close(closed: false)`).
        case turnOff
        var description: String {
            switch self {
            case .press: "the shortcut again"
            case .person(let l, let r, let dy): "the person: left edge \(Int(l)), right edge \(Int(r)), up \(Int(dy))"
            case .quit: "betterlink quits"
            case .turnOff: "the sidebar is turned off"
            }
        }
    }

    /// What starts it: the shortcut; the window followed with its sidebar on
    /// (or back from full screen), which opens without a slide (`settle`);
    /// or the sidebar's width set while it is open, which closes and opens
    /// it again without a slide (`setWidth`, `refit`).
    enum Start: CustomStringConvertible {
        case press
        case follow
        case width(Double)
        var description: String {
            switch self {
            case .press: "the shortcut"
            case .follow: "the window followed with its sidebar on"
            case .width(let w): "the sidebar's width set to \(Int(w))"
            }
        }
    }

    /// What was on screen at one tick: the browser, how much of the sidebar
    /// shows (its width between its outer edge and the seam), and whether it is hidden.
    struct Sample {
        var t: Double
        var browser: CGRect
        var shown: CGFloat
        var hidden: Bool
    }
    /// Every tick since the last press of the shortcut began.
    private(set) var samples: [Sample] = []
    /// The time of the last press, or of the person's last change, during it.
    private(set) var lastEvent: Double = 0
    /// The last tick at which the app was still moving something.
    private(set) var lastBusy: Double = 0
    /// The browser's calls before the first press.
    private(set) var callsBefore = 0
    /// The presses in this one (the first and those during it).
    private(set) var presses = 0
    /// The browser's width when the first press came.
    private(set) var widthAtPress: CGFloat = 0
    /// What the last press asked for: open (true) or closed.
    private(set) var askedOpen = false
    /// Where the person put the browser during it, if they did.
    private(set) var personPut: CGRect?

    /// How much of the sidebar shows now.
    var shownWidth: CGFloat {
        guard let p = instance.panel, p.isVisible else { return 0 }
        let outer = side == .left ? p.frame.minX : p.frame.maxX
        let seam = p.reveal ?? (side == .left ? outer + sidebarWidth : outer - sidebarWidth)
        return max(0, side == .left ? seam - outer : outer - seam)
    }

    private func sample() { samples.append(Sample(t: time, browser: fake.frame, shown: gone ? 0 : shownWidth, hidden: !open)) }

    private func press() {
        SidebarController.shared.toggle(instance)
        presses += 1
        askedOpen = !instance.hidden
        lastEvent = time
    }

    private func begin(_ start: Start) {
        switch start {
        case .press:
            press()
        case .follow, .width:
            if case .width(let w) = start { instance.setWidth(w) } else { instance.settle(window.target) }
            presses += 1
            askedOpen = !instance.hidden
            lastEvent = time
        }
    }

    /// The shortcut: the slide to its end, then the window comes to rest.
    /// `within`: the person presses it again that many seconds later, whatever
    /// is still going on (no rest).
    func toggle(within: Double? = nil) {
        fake.sliding = true
        callsBefore = fake.setCalls
        widthAtPress = fake.frame.width
        edgeWaits = 0
        presses = 0
        personPut = nil
        samples = []
        press()
        sample()
        var frames = 0
        let limit = within.map { Int($0 * 120) } ?? 2000
        while instance.sliding, frames < limit {
            time += 1.0 / 120
            instance.stepSlide()
            events()
            sample()
            frames += 1
        }
        lastBusy = time
        fake.sliding = false
        if within == nil {
            lateAnswers()
            rest()
        }
    }

    /// A browser that does what it was asked after betterlink stopped
    /// waiting for it (late by more than `WindowSteps` waits): ticked on,
    /// sampled, until it has; the window tracker reports it at rest 0.15 s
    /// after its last move, as the app would see it; and the app's moves
    /// that follow, tick by tick.
    private func lateAnswers() {
        guard fake.hasQueued, !gone else { return }
        var frames = 0
        while fake.hasQueued, frames < 1200 { tick(); sample(); frames += 1 }
        for _ in 0..<18 { tick(); sample() }
        instance.settle(window.target)
        frames = 0
        while instance.sliding, frames < 2000 {
            tick()
            lastBusy = time
            sample()
            frames += 1
        }
    }

    /// The shortcut, and `during` (each that many seconds after the press),
    /// tick by tick until the app has stopped moving anything and all of
    /// `during` has happened; then the window comes to rest.
    func toggle(during: [(at: Double, what: During)]) { carry(.press, during: during) }

    /// The window followed with its sidebar on: it opens without a slide.
    func follow(during: [(at: Double, what: During)] = []) { carry(.follow, during: during) }

    /// `start`, and `during` (each that many seconds after it), as `toggle(during:)`.
    func carry(_ start: Start, during: [(at: Double, what: During)]) {
        fake.sliding = true
        callsBefore = fake.setCalls
        widthAtPress = fake.frame.width
        edgeWaits = 0
        presses = 0
        personPut = nil
        samples = []
        let pressed = time
        begin(start)
        sample()
        lastBusy = time
        var todo = during.sorted { $0.at < $1.at }
        var frames = 0
        while instance.sliding || !todo.isEmpty, frames < 2000 {
            time += 1.0 / 120
            instance.stepSlide()
            events()
            while let next = todo.first, time - pressed >= next.at - 1e-9 {
                todo.removeFirst()
                switch next.what {
                case .press:
                    press()
                case .person(let l, let r, let dy):
                    var f = fake.frame.integral
                    f.origin.x += l
                    f.origin.y += dy
                    f.size.width = max(200, fake.behaviour.minWidth, f.width - l + r)
                    fake.person(f)
                    personPut = f
                    lastEvent = time
                    events()
                case .quit, .turnOff:
                    if case .quit = next.what { instance.giveSpaceBack() } else { instance.close(closed: false) }
                    goneUnanswered = fake.lastReadFailed
                    gone = true
                    askedOpen = false
                    lastEvent = time
                }
            }
            if instance.sliding { lastBusy = time }
            sample()
            frames += 1
        }
        fake.sliding = false
        lateAnswers()
        rest()
    }

    /// The longest a press may take to settle: 0.5 s, plus for each call the
    /// browser was sent the time it takes it as modelled (an animation, an
    /// answer that comes late, a size that lands some reads later), plus the
    /// waits nothing can avoid: a size the browser never takes is waited
    /// for twice (`WindowSteps.timeout`), and a dropped one once.
    var bound: Double {
        let b = fake.behaviour
        let calls = Double(fake.setCalls - callsBefore)
        var each = b.animation + Double(b.sizeLag) / 30
        if b.timing != .atOnce { each += b.lateBy }
        if b.stall > 0 { each += Double(b.stall) / 60 }
        var waits = 0.0
        // A browser already at its minimum takes none of a narrower size: as
        // one that takes no size, nothing tells it from a late answer or a
        // dropped call before the waits are out.
        if !b.sizesStick || b.minWidth >= widthAtPress - 1 { waits += 2 * WindowSteps.timeout * Double(presses) }
        if b.dropsSizeCall != nil { waits += WindowSteps.timeout }
        return 0.5 + calls * each + waits + edgeWaits
    }

    /// A drag that asks the browser wider while it is at or past its
    /// screen's edge on the side it grows to: macOS gives it none of that
    /// size, which nothing tells from a late answer before the waits are out.
    private var edgeWaits = 0.0

    private func growsPastTheEdge(by delta: CGFloat) -> Bool {
        guard delta < 0, side == .right, let span = screenSpan(at: fake.frame) else { return false }
        return fake.frame.maxX >= span.upperBound - 1
    }

    /// Each move the browser makes is an Accessibility event: the window is
    /// read again, the panel follows it (SidebarController.changed) and is
    /// shown or taken away as its window is.
    private func events() {
        watcher.refresh(window)
        guard !gone else { return }
        instance.follow()
        // The app puts every sidebar in its place among the windows after
        // each change (`SidebarController.arrange`): this one is the rig's own.
        instance.present(onScreen: fake.onScreen ? [window.number] : [], settled: false)
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
            if !gone { instance.settle(window.target) }
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

    private func tick() {
        time += 1.0 / 120
        instance.stepSlide()
        events()
    }

    /// The person drags the edge between the sidebar and the browser: the
    /// pointer moves there over 0.2 s (a move every 1/60 s), the button comes
    /// up, and the app finishes; then the window rests. Sampled from the
    /// button up, for the time bound.
    func personDragsEdge(by delta: CGFloat) {
        guard instance.beginResize() else { return }
        let began = fake.frame.width
        edgeWaits = growsPastTheEdge(by: delta) ? 2 * WindowSteps.timeout : 0
        fake.sliding = true
        let moves = 12
        for k in 1...moves {
            instance.resize(by: delta * CGFloat(k) / CGFloat(moves))
            tick()
            tick()
        }
        callsBefore = fake.setCalls - (instance.sliding ? 1 : 0) // the call out when the button comes up counts
        widthAtPress = began
        presses = 1
        personPut = nil
        samples = []
        lastEvent = time
        lastBusy = time
        instance.dragEnded()
        sample()
        var frames = 0
        while instance.sliding, frames < 2000 {
            tick()
            lastBusy = time
            sample()
            frames += 1
        }
        fake.sliding = false
        rest()
    }

    /// The person steps the sidebar's edge without a pointer (VoiceOver's
    /// increment, or the keyboard): each of `steps` (points) `every` seconds
    /// apart, the browser answering tick by tick meanwhile; then the step's
    /// wait (`EdgeDrag.answerWait`) runs out, as its timer would, and the
    /// window rests.
    func personSteps(_ steps: [CGFloat], every: Double) {
        fake.sliding = true
        for s in steps {
            instance.nudge(by: s)
            let until = time + every
            while time < until { tick() }
        }
        let until = time + EdgeDrag.answerWait
        while time < until { tick() }
        instance.dragEnded()
        var frames = 0
        while instance.sliding, frames < 2000 { tick(); frames += 1 }
        fake.sliding = false
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
        // Replays (a busy or stalled browser doing late what it was asked, in a burst; a late one
        // doing a size after betterlink stopped waiting for it, after calls sent since) and a browser
        // widening itself are checked at rest.
        let replays = b.timing == .busy || b.stall > 0 || (b.timing == .late && b.lateBy > 2 * WindowSteps.timeout)
        let checked = (replays || b.widensBack) ? [rig.fake.frame] : frames + [rig.fake.frame]
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
    /// `offFrom`: the frame "never further off screen" is measured from, when not `start`.
    mutating func shown(from start: CGRect, mustOpen: Bool, offFrom: CGRect? = nil, _ step: String) {
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
        noFurtherOff(than: offFrom ?? start, step)
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
        // The drag keeps the pair's outer edges (EdgeDrag): what the browser gives, the sidebar takes.
        if rig.open, !Self.near(rig.pair.minX, pair.minX) || !Self.near(rig.pair.maxX, pair.maxX) {
            problems.append("\(step): the pair's outer edges moved from \(pair.minX)...\(pair.maxX) to \(rig.pair.minX)...\(rig.pair.maxX) (browser \(rig.fake.frame), sidebar \(rig.sidebarWidth))")
        }
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

    /// The time bound (`SidebarRig.bound`): after the last press, or the
    /// person's last change during it, the app stops moving the window, and
    /// what is on screen (the browser, how much of the sidebar shows, open or
    /// closed) reaches what it ends as, within the bound. Nothing in between,
    /// a squeezed window beside a sidebar that won't open, a window past the
    /// screen's edge, a pair whose sum is wrong, lasts longer.
    mutating func timely(_ step: String) {
        let s = rig.samples
        guard let last = s.last else { return }
        var from = last.t
        for x in s.reversed() {
            guard GuardFrames.same(x.browser, last.browser), abs(x.shown - last.shown) < 2, x.hidden == last.hidden else { break }
            from = x.t
        }
        let bound = rig.bound + 1.0 / 60
        let settled = from - rig.lastEvent, busy = rig.lastBusy - rig.lastEvent
        if settled > bound {
            let was = s.last { $0.t < from }
            problems.append(String(format: "%@: settled %.0f ms after the last press or change, more than %.0f ms (until then %@, sidebar %.0f shown, %@; then %@, sidebar %.0f, %@)",
                                    step, settled * 1000, bound * 1000, "\(was?.browser ?? .zero)", Double(was?.shown ?? 0), was?.hidden == true ? "hidden" : "shown",
                                    "\(last.browser)", Double(last.shown), last.hidden ? "hidden" : "shown"))
        } else if busy > bound {
            problems.append(String(format: "%@: kept moving the window %.0f ms after the last press or change, more than %.0f ms", step, busy * 1000, bound * 1000))
        }
    }

    /// The first of `checks` that finds nothing, or else the first: for an
    /// end that two frames can rightly start from (a press during a show that
    /// came before or after the window had been put on screen to close).
    mutating func either(_ checks: [(inout RuleCheck) -> Void]) {
        var first: RuleCheck?
        for c in checks {
            var copy = self
            c(&copy)
            if copy.problems.count == problems.count { self = copy; return }
            if first == nil { first = copy }
        }
        if let first { self = first }
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
    /// The first show isn't a press: the window is followed with its sidebar
    /// on (or comes back from full screen), and it opens without a slide.
    var bySettle = false
    /// What happens while each show and hide is carried out: the shortcut
    /// again, or the person moving or resizing the browser.
    var during: [(show: [(at: Double, what: SidebarRig.During)], hide: [(at: Double, what: SidebarRig.During)])] = []

    enum Action: CustomStringConvertible {
        case moveBrowser(dx: CGFloat, dy: CGFloat)
        case resizeBrowser(left: CGFloat, right: CGFloat)
        case dragEdge(CGFloat)
        case moveSidebar(CGFloat)
        /// The sidebar's width is set (`sidebar settings set --width`): it
        /// closes and opens again without a slide; the shortcut pressed
        /// `press` seconds later, if set.
        case setWidth(Double, press: Double?)
        var description: String {
            switch self {
            case .setWidth(let w, let p): "sets the sidebar's width to \(Int(w))\(p.map { ", the shortcut \(Int($0 * 1000)) ms later" } ?? "")"

            case .moveBrowser(let dx, let dy): "moves the browser by \(Int(dx)), \(Int(dy))"
            case .resizeBrowser(let l, let r): "resizes the browser, left edge \(Int(l)), right edge \(Int(r))"
            case .dragEdge(let d): "drags the sidebar's edge \(Int(d))"
            case .moveSidebar(let dx): "moves the sidebar by \(Int(dx))"
            }
        }
    }

    var description: String {
        let ds = displays.map { "\($0.frame) visible \($0.visibleFrame) @\(Int($0.scale))x" }.joined(separator: "; ")
        return "displays [\(ds)], window \(window), sidebar \(side) \(Int(width)), browser \(behaviour)\(reduceMotion ? ", Reduce Motion" : "")"
            + "\(bySettle ? ", first opened by following the window" : ""), "
            + "the person: \(actions.map { $0.map(\.description).joined(separator: ", ") })"
            + (during.isEmpty ? "" : ", during: \(during.map { "show [\(Self.text($0.show))], hide [\(Self.text($0.hide))]" })")
    }

    private static func text(_ d: [(at: Double, what: SidebarRig.During)]) -> String {
        d.map { "\($0.what) at \(Int($0.at * 1000)) ms" }.joined(separator: ", ")
    }

    /// The shortcut pressed again once or twice, or the person moving or
    /// resizing the browser, while a show or hide is carried out. The
    /// person's change moves the window's top or left edge too: one that only
    /// narrows it where it stands is what a browser does with the size it was
    /// asked, and is taken as the browser's (WindowSteps).
    static func during(_ r: inout GuardRandom) -> [(at: Double, what: SidebarRig.During)] {
        switch r.int(0...7) {
        case 4, 5: return [(r.double(0...0.6), .press)]
        case 6: return [(r.double(0...0.8), .quit)]
        case 7: return [(r.double(0...0.8), .turnOff)]
        case 0: return [(r.double(0...0.6), .press)]
        case 1:
            let a = r.double(0...0.4)
            return [(a, .press), (a + r.double(0.02...0.4), .press)]
        case 2:
            let dy = CGFloat(r.int(2...60) * (r.bool() ? 1 : -1))
            let dx = CGFloat(r.int(-200...200))
            return [(r.double(0...0.5), .person(left: dx, right: dx, dy: dy))]
        default:
            let l = CGFloat(r.int(2...120) * (r.bool() ? 1 : -1))
            return [(r.double(0...0.5), .person(left: l, right: CGFloat(r.int(-120...120)), dy: 0))]
        }
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
                switch r.int(0...4) {
                case 4: round.append(.setWidth(Double(r.int(200...440)), press: r.bool(0.35) ? r.double(0...0.6) : nil))
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
        var c = GuardCase(displays: displays, window: w, side: r.bool() ? .left : .right, width: Double(r.int(200...440)),
                          behaviour: b, reduceMotion: r.bool(0.15), actions: actions)
        c.during = (0..<2).map { _ in (show: r.bool(0.3) ? during(&r) : [], hide: r.bool(0.3) ? during(&r) : []) }
        c.bySettle = r.bool(0.3)
        if b.tiler {
            // The fake tiling app has one home, the first frame, and acts only at rest: it can't follow a
            // window that a press during a show or hide moved on screen meanwhile (rule 4), as a real one
            // re-tiling after every move would. Its put-back is then the person's move. No presses with it.
            let noPress = { (d: [(at: Double, what: SidebarRig.During)]) in d.filter { if case .press = $0.what { false } else { true } } }
            c.during = c.during.map { (show: noPress($0.show), hide: noPress($0.hide)) }
            // Nor a new width, which closes and opens the pair again in a frame the tiling app doesn't know.
            c.actions = c.actions.map { $0.filter { if case .setWidth = $0 { false } else { true } } }
        }
        return c
    }

    /// Whether the browser can give the sidebar its least width out of `frame`.
    func canOpen(from frame: CGRect) -> Bool {
        behaviour.sizesStick && max(behaviour.minWidth, 1) <= frame.width - SidebarGeometry.widths.lowerBound
    }

    /// Show, what the person does, hide; twice, each show and hide with what
    /// happens while it is carried out. The problems found, each with its step.
    func run() -> [String] {
        let rig = SidebarRig(displays: displays, frame: window, side: side, width: width, behaviour: behaviour, reduceMotion: reduceMotion,
                             hidden: !bySettle)
        var check = RuleCheck(rig, displays: displays)
        for (round, todo) in actions.enumerated() {
            let start = rig.fake.frame
            let showDuring = round < during.count ? during[round].show : []
            if round == 0, bySettle { rig.follow(during: showDuring) } else if showDuring.isEmpty { rig.toggle() } else { rig.toggle(during: showDuring) }
            let show = "show \(round + 1)\(round == 0 && bySettle ? " (by following the window)" : "")"
            check.timely(show)
            if rig.gone {
                // Quit or turned off while it was carried out: the window has the frame it started in
                // (unless its browser wasn't answering then: see `goneUnanswered`).
                let step = "\(show), \(showDuring.last.map { "\($0.what)" } ?? "") while it was carried out"
                if !rig.goneUnanswered {
                    check.either([{ $0.hidden(from: start, sidebar: 0, wasOpen: false, step) },
                                  { $0.hidden(from: start, sidebar: 0, wasOpen: true, step) }])
                }
                break
            }
            if let put = rig.personPut {
                check.personDid(put, "\(show), moved or resized by the person while it was carried out")
            } else if rig.askedOpen {
                // Pressed more than once, it may have closed meanwhile, on screen (rule 4), and opened from there.
                let onScreen = pairFrame(browser: start, sidebar: 0, side: side)
                check.either([start, onScreen].map { from in { $0.shown(from: from, mustOpen: canOpen(from: from), offFrom: start, show) } })
            } else {
                let step = "\(show), pressed again while it was carried out"
                check.either([{ $0.hidden(from: start, sidebar: 0, wasOpen: false, step) },
                              { $0.hidden(from: start, sidebar: 0, wasOpen: true, step) }])
            }
            if !rig.open, rig.askedOpen, rig.personPut == nil {
                // Refused: the window is the person's again. Moved to a fresh frame, it stays there.
                var f = rig.fake.frame
                f.origin.x += round == 0 ? -37 : 23
                rig.personSets(f)
                check.personDid(f, "\(show), refused, then the person moves the window")
            }
            if rig.open {
                for (i, a) in todo.enumerated() {
                    guard rig.open else { break } // pressed during a change of width: closed
                    let step = "\(show), the person \(a) (\(i + 1))"
                    let before = rig.fake.frame
                    switch a {
                    case .setWidth(let w, let p) where abs(w - rig.instance.chosenWidth) < 0.5 && p == nil:
                        // The width it has already: nothing changes.
                        rig.carry(.width(w), during: [])
                        check.personDid(before, step)
                    case .setWidth(let w, let p):
                        // Closed in the pair's frame and opened again there at the new width (rules 4 and 2).
                        let pair = pairFrame(browser: before, sidebar: rig.sidebarWidth, side: side)
                        let ow = rig.sidebarWidth
                        rig.carry(.width(w), during: p.map { [($0, .press)] } ?? [])
                        check.timely(step)
                        if rig.askedOpen {
                            check.shown(from: pair, mustOpen: canOpen(from: pair), offFrom: before, step)
                        } else {
                            check.hidden(from: before, sidebar: ow, wasOpen: true, "\(step), pressed while it was carried out")
                        }
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
                        check.timely(step)
                        check.adjusted(from: pair, step)
                    case .moveSidebar(let dx):
                        rig.personMovesSidebar(by: dx)
                        check.carried(from: before, by: dx, step)
                    }
                }
            }
            let wasOpen = rig.open
            let b = rig.fake.frame, w = rig.sidebarWidth
            let hide = "hide \(round + 1)"
            if wasOpen {
                let hideDuring = round < during.count ? during[round].hide : []
                if hideDuring.isEmpty { rig.toggle() } else { rig.toggle(during: hideDuring) }
                check.timely(hide)
                if rig.gone {
                    if !rig.goneUnanswered {
                        check.hidden(from: b, sidebar: w, wasOpen: true, "\(hide), \(hideDuring.last.map { "\($0.what)" } ?? "") while it was carried out")
                    }
                    break
                }
                if let put = rig.personPut {
                    check.personDid(put, "\(hide), moved or resized by the person while it was carried out")
                } else if rig.askedOpen {
                    let pair = pairFrame(browser: b, sidebar: w, side: side)
                    check.shown(from: pair, mustOpen: canOpen(from: pair), offFrom: b, "\(hide), pressed again while it was carried out")
                    if rig.open {
                        let b2 = rig.fake.frame, w2 = rig.sidebarWidth
                        rig.toggle()
                        check.hidden(from: b2, sidebar: w2, wasOpen: true, "\(hide), then hidden")
                    }
                } else {
                    check.hidden(from: b, sidebar: w, wasOpen: true, hide)
                }
            } else {
                check.hidden(from: b, sidebar: w, wasOpen: false, hide)
            }
            if rig.open { // the person's change came after it had opened again: hidden now
                let b3 = rig.fake.frame, w3 = rig.sidebarWidth
                rig.toggle()
                check.hidden(from: b3, sidebar: w3, wasOpen: true, "\(hide), then hidden")
            }
            if !check.problems.isEmpty { break }
        }
        if Self.verbose {
            print("SidebarGuard case: \(self)\n  \(check.problems.joined(separator: "\n  "))")
            for h in rig.fake.history { print("  \(h.byPerson ? "person" : "app/browser") \(h.frame)") }
        }
        return check.problems
    }

    /// `BETTERLINK_GUARD_ONLY`: the case's frames, every one it had, printed.
    static var verbose = false
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
        let only = env["BETTERLINK_GUARD_ONLY"].map { Set($0.split(separator: ",").compactMap { Int($0) }) }
        GuardCase.verbose = only != nil
        for i in 0..<count where only?.contains(i) ?? true {
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

    /// Live on the mini at 28f7a44: Brave (its least width 615) 800 wide
    /// against the screen's right edge, the sidebar on the left at 280.
    /// Asked for 520 it stops at 615, leaving 185, less than the sidebar's
    /// least 200: the sidebar must stay closed and the window keep its frame.
    /// It was left at 615 with the sidebar open, and stuck there through the
    /// tester's next placements. Waited for, and hidden again at once.
    @Test func braveTooNarrowForTheSidebar() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        // AX top-left x, w (y 31, height 1259) of each placement, as Cocoa frames.
        let frames = [(1256.0, 800.0), (1276, 780), (1300, 756), (1356, 700), (1456, 600)].map {
            CGRect(x: $0.0, y: 0, width: $0.1, height: 1259)
        }
        for within in [nil, 0.5] as [Double?] {
            for b in [BrowserBehaviour(minWidth: 615), BrowserBehaviour(minWidth: 615, animation: 0.25)] {
                let rig = SidebarRig(displays: [screen], frame: frames[0], side: .left, width: 280, behaviour: b)
                for f in frames {
                    let start = CGRect(x: f.minX, y: f.minY, width: max(f.width, 615), height: f.height)
                    rig.personSets(start)
                    #expect(GuardFrames.same(rig.fake.frame, start), "\(b): placed at \(start), window at \(rig.fake.frame)")
                    rig.toggle()
                    let what = "\(b), \(start), hidden again \(within.map { "after \($0) s" } ?? "once it rests")"
                    if rig.open {
                        rig.toggle(within: within)
                        if within != nil { rig.rest() }
                    }
                    #expect(!rig.open, "\(what): still open")
                    #expect(GuardFrames.same(rig.fake.frame, start), "\(what): window at \(rig.fake.frame)")
                }
            }
        }
    }

    /// The same refusal as the person sees it, at 28f7a44: Brave squeezed to
    /// 615 beside an open sidebar for 2.5 s while it was asked again for a
    /// width it had already shown it can't take; a press meanwhile started
    /// it over; and the frame put back over the tester's own placements.
    /// Now: decided within 0.2 s of the browser stopping short, the sidebar
    /// never shown beside the squeezed window for longer, a press during it
    /// taken as asked (the last press wins: hide, or try again), and the
    /// person's move during it kept.
    @Test func braveTooNarrowIsRefusedAtOnce() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let start = CGRect(x: 1256, y: 0, width: 800, height: 1259)
        for b in [BrowserBehaviour(minWidth: 615), BrowserBehaviour(minWidth: 615, animation: 0.25)] {
            let rig = SidebarRig(displays: [screen], frame: start, side: .left, width: 280, behaviour: b)
            rig.toggle(during: [])
            #expect(!rig.open && GuardFrames.same(rig.fake.frame, start), "\(b): open \(rig.open), window at \(rig.fake.frame)")
            let s = rig.samples
            if let refused = s.firstIndex(where: \.hidden) {
                // The browser stopped short: its width the same from then until the refusal.
                let w = s[max(0, refused - 1)].browser.width
                let stopped = (s[..<refused].lastIndex { abs($0.browser.width - w) >= 0.5 }).map { s[$0 + 1].t } ?? s[0].t
                #expect(s[refused].t - stopped <= 0.2, "\(b): refused \(Int((s[refused].t - stopped) * 1000)) ms after the browser stopped at \(Int(w))")
            } else {
                Issue.record("\(b): never refused")
            }
            let squeezed = Double(s.filter { $0.shown > 1 && $0.browser.width < start.width - 2 }.count) / 120
            #expect(squeezed <= 0.2, "\(b): the sidebar shown beside the squeezed window for \(Int(squeezed * 1000)) ms")
            var check = RuleCheck(rig, displays: [screen])
            check.timely("refused")
            #expect(check.problems.isEmpty, "\(b): \(check.problems)")
            // One note, saying why, over the window's frame.
            #expect(SidebarRig.notices.map(\.0) == [.noRoom] && SidebarRig.notices.first.map { GuardFrames.same($0.1, start) } == true,
                    "\(b): notes \(SidebarRig.notices)")
            // Pressed again: it is known now that the window goes no narrower than 615. The note at once, nothing asked of the browser.
            let calls = rig.fake.setCalls
            rig.toggle(during: [])
            #expect(!rig.open && rig.fake.setCalls == calls && SidebarRig.notices.count == 2, "\(b): pressed again, \(rig.fake.setCalls - calls) calls")

            // Pressed again while it is carried out: the last press wins.
            for presses in [[0.05], [0.05, 0.1], [0.3], [0.1, 0.4]] {
                let rig = SidebarRig(displays: [screen], frame: start, side: .left, width: 280, behaviour: b)
                rig.toggle(during: presses.map { ($0, SidebarRig.During.press) })
                #expect(!rig.open && GuardFrames.same(rig.fake.frame, start), "\(b), pressed at \(presses): open \(rig.open), window at \(rig.fake.frame)")
                var check = RuleCheck(rig, displays: [screen])
                check.timely("pressed at \(presses)")
                #expect(check.problems.isEmpty, "\(b): \(check.problems)")
            }
            // The person moves it while it is carried out: their frame stays.
            for at in [0.0, 0.02, 0.08, 0.3, 0.6] {
                let rig = SidebarRig(displays: [screen], frame: start, side: .left, width: 280, behaviour: b)
                rig.toggle(during: [(at, .person(left: -150, right: -150, dy: -20))])
                let put = rig.personPut ?? .null
                #expect(!rig.open && GuardFrames.same(rig.fake.frame, put), "\(b), moved at \(at) s to \(put): open \(rig.open), window at \(rig.fake.frame)")
                // And again, now the window is closed: it stays where it is put.
                let f = rig.fake.frame.offsetBy(dx: 40, dy: 0)
                rig.personSets(f)
                #expect(GuardFrames.same(rig.fake.frame, f), "\(b), moved at \(at) s, then to \(f): window at \(rig.fake.frame)")
            }
        }
    }

    /// PR 83's accessibility steps of the edge (VoiceOver's increment, 10 pt
    /// each, about 55 ms apart, held past the limit), with the sidebar on the
    /// left of a browser that takes 30 to 100 ms per call: each step adds to
    /// the width last asked, none is lost to a call still out, and they reach
    /// the 440 pt limit; one step back gives 430. Live at 9eb0125 they ended at
    /// 360 (Chrome for Testing) and 390 (Brave) on the left, 440 on the right.
    @Test func edgeStepsAddUpOnEitherSide() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let window = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        for side in SidebarSide.allCases {
            let late = [0.03, 0.04, 0.05, 0.1].map { BrowserBehaviour(timing: .late, lateBy: $0) }
            for b in late + [BrowserBehaviour(), BrowserBehaviour(animation: 0.25)] {
                let rig = SidebarRig(displays: [screen], frame: window, side: side, width: 280, behaviour: b)
                rig.toggle()
                #expect(rig.open && abs(rig.sidebarWidth - 280) < 2, "\(side) \(b): \(rig.sidebarWidth)")
                rig.personSteps(Array(repeating: 10, count: 18), every: 0.055)
                #expect(abs(rig.sidebarWidth - 440) < 2, "\(side) \(b): 18 steps of 10 ended at \(rig.sidebarWidth)")
                #expect(GuardFrames.same(rig.pair, window), "\(side) \(b): the pair at \(rig.pair)")
                rig.personSteps([-10], every: 0.055)
                #expect(abs(rig.sidebarWidth - 430) < 2, "\(side) \(b): one step back ended at \(rig.sidebarWidth)")
                #expect(GuardFrames.same(rig.pair, window), "\(side) \(b): the pair at \(rig.pair)")
            }
        }
    }

    /// Review of 1cb4342, F1: a window followed with its sidebar on opens
    /// without a slide (`settle`: when it is first followed, back from full
    /// screen, a new width). Hidden 50 ms later, while the browser was still
    /// narrowing, the closed frame was worked out from where the browser was
    /// on screen then plus the sidebar's width: a left half 1028 wide ended
    /// 1299 (macOS 27's animation) or 1308 (an answer 0.3 s late). The same
    /// for quitting and for turning the sidebar off. While an open is under
    /// way, the closed frame is the one it opened in.
    @Test func hidingWhileAnOpenByFollowingIsUnderWay() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let halves = [CGRect(x: 0, y: 0, width: 1028, height: 1259), CGRect(x: 1028, y: 0, width: 1028, height: 1259),
                      CGRect(x: 0, y: 0, width: 2056, height: 1259)]
        let behaviours = [BrowserBehaviour(animation: 0.25), BrowserBehaviour(timing: .late, lateBy: 0.3), BrowserBehaviour(sizeLag: 3),
                          BrowserBehaviour(timing: .busy, lateBy: 0.2)]
        for start in halves {
            for b in behaviours {
                for side in SidebarSide.allCases {
                    // A browser that isn't answering at all when betterlink quits is sent nothing (it would hold quitting up).
                    for what in b.timing == .busy ? [SidebarRig.During.press] : [.press, .quit, .turnOff] {
                        for at in [0.0, 0.05, 0.15] {
                            let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: b, hidden: false)
                            rig.follow(during: [(at, what)])
                            let step = "\(start) \(b) \(side), \(what) \(Int(at * 1000)) ms into the open"
                            #expect(!rig.open, "\(step): still open")
                            #expect(GuardFrames.same(rig.fake.frame, start), "\(step): the window at \(rig.fake.frame)")
                            var check = RuleCheck(rig, displays: [screen])
                            check.timely(step)
                            #expect(check.problems.isEmpty, "\(check.problems)")
                        }
                    }
                }
            }
        }
    }

    /// Review of 1cb4342, F1, the same with the width set while it is open
    /// (`refit`: closed and opened again without a slide), and the shortcut
    /// pressed while it is carried out: the window takes the pair's frame.
    @Test func hidingWhileANewWidthIsUnderWay() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let start = CGRect(x: 0, y: 0, width: 1028, height: 1259)
        for b in [BrowserBehaviour(animation: 0.25), BrowserBehaviour(timing: .late, lateBy: 0.3)] {
            for side in SidebarSide.allCases {
                for at in [0.0, 0.05, 0.2, 0.4] {
                    let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: b)
                    rig.toggle()
                    #expect(rig.open, "\(b) \(side): didn't open")
                    rig.carry(.width(360), during: [(at, .press)])
                    let step = "\(b) \(side), the width set to 360, the shortcut \(Int(at * 1000)) ms later"
                    #expect(!rig.open, "\(step): still open")
                    #expect(GuardFrames.same(rig.fake.frame, start), "\(step): the window at \(rig.fake.frame)")
                }
            }
        }
    }

    /// Review of 1cb4342, F2: a browser that answers after betterlink has
    /// stopped waiting (two waits of `WindowSteps.timeout`) was refused with
    /// the "didn't make room" note, and its late answer then narrowed the
    /// window with the sidebar closed: full screen, sidebar left, 1.3 s late
    /// and later ended at 0, 0, 1776, 1259, 280 pt lost. However late it
    /// answers, the four rules hold: the answer opens the sidebar (it was
    /// asked to show), and a hide whose calls land late ends in the pair's frame.
    @Test func aBrowserThatAnswersLateLosesNoWidth() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let start = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        for side in SidebarSide.allCases {
            for late in [0.5, 1.0, 1.3, 1.5, 2.0, 3.0] {
                for timing in [BrowserBehaviour.Timing.late, .busy] {
                    let b = BrowserBehaviour(timing: timing, lateBy: late)
                    let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: b)
                    rig.toggle()
                    var check = RuleCheck(rig, displays: [screen])
                    check.timely("\(b) \(side): show")
                    check.shown(from: start, mustOpen: true, "\(b) \(side): show")
                    let w = rig.sidebarWidth, browser = rig.fake.frame
                    rig.toggle()
                    check.timely("\(b) \(side): hide")
                    check.hidden(from: browser, sidebar: w, wasOpen: true, "\(b) \(side): hide")
                    #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                }
            }
            // Opened by a browser that answers at once, hidden after it has turned slow.
            for late in [1.3, 2.0, 3.0] {
                for timing in [BrowserBehaviour.Timing.late, .busy] {
                    let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: BrowserBehaviour())
                    rig.toggle()
                    #expect(rig.open, "\(side): didn't open")
                    rig.fake.behaviour = BrowserBehaviour(timing: timing, lateBy: late)
                    let w = rig.sidebarWidth, browser = rig.fake.frame
                    rig.toggle()
                    var check = RuleCheck(rig, displays: [screen])
                    check.timely("\(side), hidden by a browser \(rig.fake.behaviour)")
                    check.hidden(from: browser, sidebar: w, wasOpen: true, "\(side), hidden by a browser \(rig.fake.behaviour)")
                    #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                }
            }
        }
    }

    /// Review of 1cb4342, F3: quitting gave each window its space back one
    /// after another, each waited for on the main thread (up to 4 x 0.6 s a
    /// window). Every window gets its width back, and the whole wait is
    /// bounded however many windows there are: at most 4 x `WindowSteps.timeout`.
    @Test func quittingGivesEveryWindowBackWithinOneBound() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let frames = (0..<6).map { CGRect(x: CGFloat($0) * 150, y: 0, width: 1200, height: 1259) }
        // Browsers that answer each call 0.5 s late, and browsers that no longer take a size at all.
        for (late, slow) in [(BrowserBehaviour(timing: .late, lateBy: 0.5), false), (BrowserBehaviour(positionOnly: true), true)] {
            for side in SidebarSide.allCases {
                let rigs = frames.map { SidebarRig(displays: [screen], frame: $0, side: side, width: 280, behaviour: BrowserBehaviour()) }
                for r in rigs { r.toggle(); #expect(r.open, "\(side): didn't open") }
                let pairs = rigs.map { pairFrame(browser: $0.fake.frame, sidebar: $0.sidebarWidth, side: side) }
                var clock = (rigs.map(\.now).max() ?? 0) + 10
                let began = clock
                for r in rigs {
                    r.fake.behaviour = late
                    r.fake.now = { clock }
                    r.instance.clock = { clock }
                    r.instance.pause = { clock += $0 }
                }
                SidebarController.shared.giveSpaceBack(of: rigs.map(\.instance), clock: { clock }, pause: { clock += $0 })
                let took = clock - began
                #expect(took <= 4 * WindowSteps.timeout + 0.05, "\(late) \(side): quitting waited \(Int(took * 1000)) ms for \(rigs.count) windows")
                if !slow {
                    for (r, p) in zip(rigs, pairs) { #expect(GuardFrames.same(r.fake.frame, p), "\(late) \(side): a window at \(r.fake.frame), wanted \(p)") }
                }
            }
        }
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
                #expect(SidebarRig.notices.isEmpty, "\(w) \(side): a note though it opened")
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
