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
    /// Takes any size, then widens itself back to `minWidth` 50 ms after
    /// taking a narrower one (within the 150 ms a call is watched for once
    /// the window has changed), keeping its top left.
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
    /// macOS 27's animation can begin late: a set's animation starts this
    /// many seconds after it (the window doesn't move meanwhile: "not
    /// started"); a set meanwhile cancels it, as one in flight.
    var animationDelay: Double = 0
    /// macOS 27 can hold an animation partway (the reviewer of 596bc4e
    /// reproduced 2056 to 1900, still for 250 ms, then on to 1776): every
    /// other animation stands still this long once `holdAt` of its time has
    /// passed, then goes on.
    var animationHold: Double = 0
    var holdAt: Double = 0.4
    /// Which animations hold: every `holdsEvery`-th, from the `holdsFirst`-th.
    var holdsEvery = 2
    var holdsFirst = 1
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
    /// Hung: every Accessibility call to it waits out the messaging timeout
    /// (1 s unless lowered, `limitWaiting`) and gets no answer; the window
    /// server still shows the window.
    var hangs = false
    /// Its app's AXEnhancedUserInterface is on when the case begins (Nick's
    /// Chrome and Brave on macOS 27.2.1): while it is on, macOS animates
    /// every set over about 250 ms (ease-out, the first change 16 to 31 ms
    /// in), and a later set cuts the one in flight short where it has got
    /// to; off, every set lands at once (`FakeApps`).
    var enhancedUI = false
    /// Its flag can't be set off (the set is refused).
    var enhancedStuck = false

    /// Sizes it is given end up taken (late, once dropped, or after a tiling app, included).
    var sizesStick: Bool { !positionOnly && revertReads == 0 }

    var description: String {
        var s = [timing == .atOnce ? timing.rawValue : "\(timing.rawValue) by \(Int(lateBy * 1000)) ms"]
        if minWidth > 0 { s.append("minimum \(Int(minWidth))\(widensBack ? " (widens back to it)" : "")") }
        if positionOnly { s.append("applies the position, not the size") }
        if revertReads > 0 { s.append("reads back the asked size \(revertReads)x, then reverts") }
        if let n = dropsSizeCall { s.append("drops size change #\(n)") }
        if tiler { s.append("a tiling app puts it back once") }
        if animation > 0 { s.append("macOS 27: each set animated over \(Int(animation * 1000)) ms\(animationDelay > 0 ? ", starting \(Int(animationDelay * 1000)) ms late" : "")\(animationHold > 0 ? ", every other one held \(Int(animationHold * 1000)) ms \(Int(holdAt * 100))% of the way" : ""), cut short by the next") }
        if sizeLag > 0 { s.append("macOS 27: a size lands \(sizeLag) reads later, dropped by anything sent meanwhile") }
        if stall > 0 { s.append("stops answering for \(stall) calls in every \(stall + every)\(staleReads ? ", reading stale" : "")") }
        if hangs { s.append("hung: every call waits out its time") }
        if enhancedUI { s.append("enhanced UI on\(enhancedStuck ? ", can't be set off" : "")") }
        return s.joined(separator: ", ")
    }

    static func random(_ r: inout GuardRandom) -> BrowserBehaviour {
        var b = BrowserBehaviour()
        b.timing = r.pick([.atOnce, .atOnce, .late, .busy])
        // Most answer within half a second; some, late or busy (a busy one doesn't answer reads
        // either), up to 3 s after each call: past betterlink's waits, and up to its cap on a whole
        // show or hide (`GuardTiming.cap`).
        let long = r.bool(0.3)
        b.lateBy = long && b.timing != .atOnce ? r.double(0.5...3) : r.double(0.02...0.5)
        if b.timing == .atOnce, r.bool(0.3) { b.sizeLag = r.int(1...4) }
        if b.timing == .atOnce, b.sizeLag == 0, r.bool(0.35) {
            b.animation = r.double(0.05...0.35)
            if r.bool(0.4) { b.animationDelay = r.double(0.02...0.45) }
            if r.bool(0.3) { b.animationHold = r.double(0.1...0.3); b.holdAt = r.double(0.2...0.7) }
        }
        switch r.int(0...9) {
        case 0: b.positionOnly = true
        case 1: b.revertReads = r.int(1...6)
        default: break
        }
        if r.bool(0.4) { b.minWidth = CGFloat(r.int(300...1400)); b.widensBack = r.bool(0.25) }
        if r.bool(0.15) { b.dropsSizeCall = r.int(1...8) }
        if r.bool(0.15) { b.tiler = true }
        if b.timing == .atOnce, r.bool(0.25) { b.stall = r.int(2...12); b.every = r.int(1...8); b.staleReads = r.bool() }
        if r.bool(0.4) { b.enhancedUI = true; b.enhancedStuck = r.bool(0.15) }
        return b
    }
}

/// The browsers' apps as betterlink's `EnhancedUI` sees them: each app's
/// AXEnhancedUserInterface by pid, every read and set of it, and the
/// process's start time. A hung browser's calls wait out their time and get
/// no answer, as its windows' do. A set answers -25208
/// (kAXErrorNotImplemented) and takes, as Chromium on macOS 27 does;
/// `stuck`: it answers that and doesn't take; `ignores`: it answers success
/// and doesn't take.
@MainActor
final class FakeApps: EnhancedUIApp {
    static let shared = FakeApps()
    var flags: [pid_t: Bool] = [:]
    var stuck: Set<pid_t> = []
    var ignores: Set<pid_t> = []
    var launches: [pid_t: Date] = [:]
    /// Processes with no start time to be had.
    var unstarted: Set<pid_t> = []
    private(set) var lastAnswer: Int32 = 0
    /// Every call, in order: a read (nil) or the value set.
    private(set) var calls: [(pid: pid_t, set: Bool?)] = []
    private(set) var missed = false
    /// The fake browsers of each app, for whether it hangs and on whose clock it waits.
    private var browsers: [pid_t: [Weak]] = [:]
    private struct Weak { weak var fake: FakeBrowser? }

    func register(_ fake: FakeBrowser, pid: pid_t) { browsers[pid, default: []].append(Weak(fake: fake)) }
    func flag(_ pid: pid_t) -> Bool { flags[pid] ?? false }

    /// Forgets the apps of the cases before (their fake browsers are gone with their rigs).
    /// Several rigs that are windows of one browser: the first resets, the others pass `freshApps: false`.
    func reset() {
        flags = [:]; stuck = []; ignores = []; calls = []; launches = [:]; unstarted = []
        browsers = [:]
    }

    private func hung(_ pid: pid_t, _ wait: Double) -> Bool {
        guard let f = browsers[pid]?.compactMap(\.fake).first(where: { $0.behaviour.hangs }) else { missed = false; return false }
        f.wait(min(1, wait))
        missed = true
        return true
    }

    func read(_ pid: pid_t, wait: Double) -> Bool? {
        calls.append((pid, nil))
        return hung(pid, wait) ? nil : flags[pid] ?? false
    }

    func set(_ pid: pid_t, _ on: Bool, wait: Double) -> Bool {
        calls.append((pid, on))
        if hung(pid, wait) { lastAnswer = -25204; return false }
        if ignores.contains(pid) { lastAnswer = 0; return true }
        lastAnswer = -25208
        if !on, stuck.contains(pid) { return false }
        flags[pid] = on
        return false
    }

    func launched(_ pid: pid_t) -> Date? { unstarted.contains(pid) ? nil : launches[pid] ?? Date(timeIntervalSince1970: 1_000_000) }
}

/// A browser window as macOS and a browser treat the sidebar's requests:
/// position and size are separate calls in Accessibility's coordinates, and
/// macOS limits each size to what fits on the display the window is on at
/// that moment. A move is not limited.
@MainActor
final class FakeBrowser: WindowHandle {
    /// Its app's pid (`FakeApps`).
    var pid: pid_t = 0
    /// What a set animates over now: macOS 27's animation (`animation`), or,
    /// while its app's enhanced UI is on, the system's 250 ms.
    var animating: Double { behaviour.animation > 0 ? behaviour.animation : FakeApps.shared.flag(pid) ? FakeBrowser.enhancedAnimation : 0 }
    static let enhancedAnimation = 0.25

    /// The frame on screen now: where the window server shows it. Mostly
    /// the window's own (`real`); a set armed to show late (`showsLate`)
    /// leaves the frame from before on screen for a while.
    var frame: CGRect {
        if let l = lag {
            if now() < l.until { return l.shown }
            lag = nil
        }
        return real
    }

    /// The window's frame (mid-animation: where the animation has got to).
    private var real: CGRect {
        guard let a = anim else { return base }
        var e = now() - a.start - behaviour.animationDelay
        // Held partway: still for `animationHold`, then on.
        if a.holds, behaviour.animationHold > 0 {
            let at = behaviour.holdAt * behaviour.animation
            if e > at { e = e < at + behaviour.animationHold ? at : e - behaviour.animationHold }
        }
        let u = a.length > 0 ? e / a.length : 1
        if u >= 1 { base = a.to; anim = nil; return base }
        if u <= 0 { return a.from } // not started
        let f = CGFloat(u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2)
        return CGRect(x: a.from.minX + (a.to.minX - a.from.minX) * f, y: a.from.minY + (a.to.minY - a.from.minY) * f,
                      width: a.from.width + (a.to.width - a.from.width) * f, height: a.from.height + (a.to.height - a.from.height) * f)
    }
    private var base: CGRect
    private var anim: (from: CGRect, to: CGRect, start: Double, holds: Bool, length: Double)?
    /// Animations started, for holding every other one.
    private var animations = 0
    /// The rig's clock, for animations.
    var now: () -> Double = { 0 }
    /// What a read gives: the target of an animation at once.
    private var readFrame: CGRect { anim?.to ?? real }
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
        // A call to a browser that isn't answering gets no answer in time (Accessibility's
        // cannotComplete), though the browser does it later.
        if inStall { missed = true }
        if inStall, beforeStall == nil { beforeStall = real }
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

    /// Waiting on the rig's clock: what a hung browser's call costs.
    var wait: (Double) -> Void = { _ in }
    /// How long one call may wait for it (AXUIElementSetMessagingTimeout): 1 s, as betterlink sets it.
    private var waitLimit = 1.0
    func limitWaiting(_ seconds: Double) { waitLimit = seconds }
    /// The last call got no answer in time (a hung browser, or a stalled one).
    private(set) var missed = false
    /// Whether this call finds it hung: then it waits out its time.
    private func hung() -> Bool {
        missed = behaviour.hangs
        if behaviour.hangs { wait(min(1, waitLimit)) }
        return behaviour.hangs
    }
    /// When a browser that widens itself back does so (`widensBack`).
    private var widenAt: Double?

    /// It has been asked something it hasn't done yet (late, busy, or a size on its way).
    var hasQueued: Bool { !queued.isEmpty || pendingSize != nil }
    /// The last read of its position or size got no answer (busy or stalled).
    private(set) var lastReadFailed = false

    private func tick() {
        if let at = widenAt, now() >= at {
            widenAt = nil
            // The size it took (on macOS 27 still on its way on screen), widened back.
            let f = readFrame
            if f.width < behaviour.minWidth - 0.5 { set(CGRect(x: f.minX, y: f.minY, width: behaviour.minWidth, height: f.height)) }
        }
        guard var p = pendingSize else { return }
        p.reads -= 1
        if p.reads <= 0 { pendingSize = nil; take(p.size) } else { pendingSize = p }
    }

    func position() -> CGPoint? {
        if hung() { lastReadFailed = true; return nil }
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
        if hung() { lastReadFailed = true; return nil }
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
    /// Each of them, when, in Accessibility's coordinates: a call sent again is seen.
    private(set) var sent: [(t: Double, size: CGSize?, position: CGPoint?)] = []

    /// One set, live, that showed late: the window server kept the frame
    /// from before on screen `by` seconds after it (MINI-16 on macOS 27,
    /// 1df43a3: one late set mid-glide), reads giving the new frame. Armed for
    /// the `n`-th set call from now that changes the window.
    func showsLate(call n: Int, by d: Double) { lagAt = setCalls + n; lagArmed = d }
    private var lag: (shown: CGRect, until: Double)?
    private var lagAt = 0
    private var lagArmed = 0.0
    /// One set call, live, that held the caller: the browser took `by`
    /// seconds to answer it (its main thread busy), and its change landed
    /// at once. Armed for the `n`-th set call from now.
    func holdsCaller(call n: Int, by d: Double) { holdAt = setCalls + n; holdFor = d }
    private var holdAt = 0
    private var holdFor = 0.0
    /// A position sent right after a size (a left-side glide's pair) that
    /// holds the caller now and then: every `every`-th such position waits
    /// `by` seconds for the browser, busy with the size, and lands at once,
    /// both calls shown together. Live a left glide gave way as slow after a
    /// few motions, flag on and off, a right one never (MINI-16, macOS 27).
    var pairedPositionHolds: (every: Int, by: Double)?
    private var pairedPositions = 0
    private var lastSizeAt: Double?
    private func holdPaired(position: Bool) {
        if !position { lastSizeAt = now(); return }
        guard let h = pairedPositionHolds, let at = lastSizeAt, now() - at < 1e-9 else { return }
        pairedPositions += 1
        if pairedPositions % h.every == 0 { wait(h.by) }
    }

    private func holdCaller() {
        guard holdFor > 0, setCalls == holdAt else { return }
        let d = holdFor
        holdFor = 0
        wait(d)
    }

    func setPosition(_ p: CGPoint) {
        defer { holdCaller(); holdPaired(position: true) }
        setCalls += 1
        sent.append((now(), nil, p))
        if hung() || fullScreen { return }
        pendingSize = nil
        due()
        if behaviour.timing == .busy || stalled() { return enqueue((nil, p)) }
        move(to: p)
    }

    func setSize(_ s: CGSize) {
        defer { holdCaller(); holdPaired(position: false) }
        setCalls += 1
        sent.append((now(), s, nil))
        if hung() || fullScreen { return }
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

    /// In native full screen: the whole display, on a Space of its own, its
    /// sets ignored (macOS doesn't resize a full screen window); leaving it
    /// puts back the frame it had.
    private(set) var fullScreen = false
    private var beforeFullScreen: CGRect?
    func isFullScreen() -> Bool? { fullScreen }

    func enterFullScreen(_ display: CGRect) {
        beforeFullScreen = real
        lag = nil
        anim = nil
        base = display
        fullScreen = true
        history.append((display, true))
    }

    func exitFullScreen() {
        guard let f = beforeFullScreen else { return }
        fullScreen = false
        base = f
        history.append((f, true))
    }

    /// What it does once it gets to them: what it was asked, then its own
    /// minimum, then a tiling app's one put-back. True when the frame changed.
    @discardableResult
    func answer() -> Bool {
        let was = real
        if let p = pendingSize { pendingSize = nil; take(p.size) }
        beforeStall = nil
        let todo = queued
        queued = []
        for q in todo {
            if let s = q.size { if behaviour.timing == .atOnce { take(s) } else { apply(s) } }
            if let p = q.position { move(to: p) }
        }
        if behaviour.widensBack, real.width < behaviour.minWidth - 0.5 {
            set(CGRect(x: real.minX, y: real.minY, width: behaviour.minWidth, height: real.height))
        }
        if let home = tilerHome, real != home, history.contains(where: { !$0.byPerson }) {
            tilerHome = nil
            set(home)
            tilerPut = home
        }
        return real != was
    }

    /// Where a tiling app put the window back, since the rig last asked
    /// (`takeTilerPut`): another app's change, which stands as the person's.
    private var tilerPut: CGRect?
    func takeTilerPut() -> CGRect? { defer { tilerPut = nil }; return tilerPut }

    /// The person moves or resizes the window.
    func person(_ f: CGRect) {
        queued = []
        pendingSize = nil
        widenAt = nil
        reportReads = 0
        tilerHome = nil
        anim = nil
        lag = nil
        base = f
        history.append((f, true))
    }

    private func move(to p: CGPoint) {
        let f = real
        set(CGRect(x: p.x, y: height - p.y - f.height, width: f.width, height: f.height))
    }

    /// The top left stays; the size is limited to what fits on the display
    /// the window is on now, and to the browser's minimum.
    private func apply(_ s: CGSize) {
        let frame = real
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
        if behaviour.widensBack, w < behaviour.minWidth - 0.5 { widenAt = now() + 0.05 }
    }

    /// Where it goes: at once, or (macOS 27) animated from where it is now,
    /// cutting short the animation in flight there.
    private func set(_ f: CGRect) {
        let at = real
        if lagArmed > 0, setCalls >= lagAt, f != at {
            // The window server shows this change, and what follows it meanwhile, only after a while.
            lag = (frame, now() + lagArmed)
            lagArmed = 0
        }
        if anim != nil { base = at; anim = nil; history.append((at, false)) }
        guard f != at else { return }
        if animating > 0 {
            animations += 1
            anim = (at, f, now(), animations >= behaviour.holdsFirst && (animations - behaviour.holdsFirst) % behaviour.holdsEvery == 0, animating)
        } else {
            base = f
        }
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
    /// The pid every rig's browser has unless a test gives it another: several
    /// rigs are then windows of one browser.
    nonisolated static let browserPid: pid_t = 50_001
    let pid: pid_t

    let reduceMotion: Bool

    init(displays: [Display], frame: CGRect, side: SidebarSide, width: Double, behaviour: BrowserBehaviour, reduceMotion: Bool = false,
         hidden: Bool = true, pid: pid_t = SidebarRig.browserPid, freshApps: Bool = true) {
        self.reduceMotion = reduceMotion
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
        self.pid = pid
        window.target.pid = pid
        fake.pid = pid
        if freshApps {
            FakeApps.shared.reset()
            EnhancedUI.shared.forgetHolds()
            try? FileManager.default.removeItem(at: EnhancedUI.shared.journal)
        }
        EnhancedUI.shared.app = FakeApps.shared
        FakeApps.shared.register(fake, pid: pid)
        if FakeApps.shared.flags[pid] == nil || freshApps {
            FakeApps.shared.flags[pid] = behaviour.enhancedUI
            if behaviour.enhancedStuck { FakeApps.shared.stuck.insert(pid) }
        }
        flagBefore = FakeApps.shared.flag(pid)
        instance = SidebarInstance(window: window, sidebar: controller, hidden: hidden, width: width)
        instance.clock = { [unowned self] in self.time }
        // Quitting waits on the rig's clock, as everything else does.
        instance.pause = { [unowned self] in self.time += $0 }
        fake.now = { [unowned self] in self.time }
        fake.wait = { [unowned self] in self.time += $0 }
        instance.reducesMotion = { reduceMotion }
        SidebarRig.notices = []
        SidebarRig.noticeTimes = []
        SidebarInstance.tell = { [unowned self] notice, frame in
            SidebarRig.notices.append((notice, frame))
            SidebarRig.noticeTimes.append(self.time)
            self.noticeShows = self.panelShows.count
        }
        SidebarPanel.watch = { [weak self] p in
            guard let self, self.instance.panel == nil || p === self.instance.panel else { return }
            self.panelShows.append((self.time, self.gone ? 0 : self.shown(of: p), self.gone ? 0 : self.over(of: p), !self.gone && p.isVisible,
                                    self.instance.opensWithoutSlide))
        }
    }

    /// Each change to what shows of the panel (its outline, or whether it is
    /// ordered in) since the last press: when, and how much of the sidebar
    /// showed then. The window server draws whatever the panel last had, so
    /// a moment of a full panel between two ticks is seen here though no
    /// tick's sample has it.
    private(set) var panelShows: [(t: Double, shown: CGFloat, over: CGFloat, ordered: Bool, opening: Bool)] = []
    /// Where quitting or turning the sidebar off came in `panelShows`.
    private(set) var goneShows: Int?
    /// The app calls (`FakeApps`) before the last press.
    private(set) var appCallsBefore = 0
    /// Where the last refusal's note came in `panelShows`.
    private(set) var noticeShows: Int?
    /// Where the last press came in `panelShows`.
    private(set) var lastPressShows = 0

    /// Its browser's enhanced UI when the rig was made: what it must be again after every motion.
    let flagBefore: Bool

    /// The notes shown since the rig was made: why the sidebar didn't open, and over which frame.
    static var notices: [(SidebarNotice, CGRect)] = []
    /// When each was shown, on the rig's clock.
    static var noticeTimes: [Double] = []

    /// betterlink quit, or let the window go (`During.quit`, `.turnOff`): no sidebar any more.
    private(set) var gone = false
    /// When it did, the browser wasn't answering (hung): its window is left
    /// as it is, the person's, since each call to it would hold up quitting.
    private(set) var goneUnanswered = false
    /// When it quit or let the window go, and how many calls the browser had been sent by then.
    private(set) var goneAt: (t: Double, calls: Int)?
    /// How long quitting held the app up (`During.quitHung`), if it quit.
    private(set) var quitTook: Double?
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
        /// betterlink quits while the browser is hung: every call to it waits
        /// out its time. Quitting must still end within its bound.
        case quitHung
        /// The sidebar is turned off, or the browser no longer attached: the window is let go (`close(closed: false)`).
        case turnOff
        var description: String {
            switch self {
            case .press: "the shortcut again"
            case .person(let l, let r, let dy): "the person: left edge \(Int(l)), right edge \(Int(r)), up \(Int(dy))"
            case .quit: "betterlink quits"
            case .quitHung: "betterlink quits, the browser hung"
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
        /// How far the panel's body, as shown, lies over the browser (`panelOver`).
        var over: CGFloat = 0
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
    /// When each began, on the rig's clock, how many calls the browser had been sent by then, and whether it was
    /// a show or a hide (not a new width, which closes to the frame a press meanwhile closes to too): the first (a
    /// press, the window followed, a new width) and each press during it.
    private(set) var pressedAt: [(t: Double, calls: Int, toggles: Bool)] = []
    /// The browser's width when the first press came.
    private(set) var widthAtPress: CGFloat = 0
    /// What the last press asked for: open (true) or closed.
    private(set) var askedOpen = false
    /// Where the person put the browser during it, if they did; and whether
    /// the motion was over by then (the sidebar open at rest), from where, and the sidebar's width then.
    private(set) var personPut: CGRect?
    private(set) var personAtRest = false
    private(set) var personFrom = CGRect.null
    private(set) var personWidth: CGFloat = 0

    /// How much of the sidebar shows now.
    var shownWidth: CGFloat { instance.panel.map(shown(of:)) ?? 0 }

    private func shown(of p: SidebarPanel) -> CGFloat {
        guard p.isVisible else { return 0 }
        let outer = side == .left ? p.frame.minX : p.frame.maxX
        let seam = p.reveal ?? (side == .left ? outer + sidebarWidth : outer - sidebarWidth)
        return max(0, side == .left ? seam - outer : outer - seam)
    }

    /// How far the panel's body, as shown, lies over the browser's content:
    /// the strip from its outer edge to the seam (`reveal`, or the whole
    /// sidebar), against the browser's frame on screen. Its corner fills
    /// over the window's rounded corners (`reach`) are not its body.
    var panelOver: CGFloat { gone ? 0 : instance.panel.map(over(of:)) ?? 0 }

    private func over(of p: SidebarPanel) -> CGFloat {
        guard p.isVisible else { return 0 }
        let b = fake.frame
        let left = p.attachedSide == .left
        let lo = left ? p.frame.minX : max(p.reveal ?? p.frame.minX, p.frame.minX + p.reach)
        let hi = left ? min(p.reveal ?? p.frame.maxX, p.frame.maxX - p.reach) : p.frame.maxX
        return max(0, min(hi, b.maxX) - max(lo, b.minX))
    }

    private func sample() {
        samples.append(Sample(t: time, browser: fake.frame, shown: gone ? 0 : shownWidth, hidden: !open, over: panelOver))
    }

    private func press() {
        pressedAt.append((time, fake.sent.count, true))
        lastPressShows = panelShows.count
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
            pressedAt.append((time, fake.sent.count, { if case .follow = start { true } else { false } }()))
            lastPressShows = panelShows.count
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
        pressedAt = []
        personPut = nil
        tilerPut = nil
        samples = []
        panelShows = []
        noticeShows = nil
        appCallsBefore = FakeApps.shared.calls.count
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
            tilerPut = fake.takeTilerPut()
        }
    }

    /// Where a tiling app put the window back during the last press, at rest
    /// after betterlink's calls: another app's change.
    private(set) var tilerPut: CGRect?

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
        pressedAt = []
        personPut = nil
        tilerPut = nil
        quitTook = nil
        goneShows = nil
        noticeShows = nil
        samples = []
        panelShows = []
        appCallsBefore = FakeApps.shared.calls.count
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
                    // After the motion is over: a resize of the open pair at rest, weighed as any (`placedPushingTheSidebarOff`).
                    personAtRest = !instance.sliding && open
                    personFrom = fake.frame
                    personWidth = sidebarWidth
                    var f = fake.frame.integral
                    f.origin.x += l
                    f.origin.y += dy
                    f.size.width = max(200, fake.behaviour.minWidth, f.width - l + r)
                    fake.person(f)
                    personPut = f
                    lastEvent = time
                    events()
                case .quit, .quitHung, .turnOff:
                    if case .quitHung = next.what { fake.behaviour.hangs = true }
                    let began = time
                    goneAt = (time, fake.sent.count)
                    goneShows = panelShows.count
                    if case .turnOff = next.what { instance.close(closed: false) } else { instance.giveSpaceBack() }
                    if case .quitHung = next.what { quitTook = time - began }
                    // Hung, its flag's read misses first, and its windows are sent nothing.
                    goneUnanswered = fake.missed || fake.behaviour.hangs
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
        tilerPut = fake.takeTilerPut()
    }

    /// The longest a press may take to settle: 0.5 s, plus for each call the
    /// browser was sent the time it takes it as modelled (an animation, and
    /// how late it starts; an answer that comes late; a size that lands some
    /// reads later), plus the waits nothing can avoid: a size the browser
    /// never takes is waited for up to the cap on a show or hide
    /// (`GuardTiming.cap`), and then, sent once more with the final frame
    /// (`WindowSteps.resends`), twice more (`WindowSteps.timeout`); a dropped
    /// one once.
    var bound: Double {
        let b = fake.behaviour
        let calls = Double(fake.setCalls - callsBefore)
        var each = b.animation + b.animationDelay + b.animationHold + Double(b.sizeLag) / 30
        if b.animation == 0, b.enhancedUI, b.enhancedStuck { each += FakeBrowser.enhancedAnimation }
        if b.timing != .atOnce { each += b.lateBy }
        if b.stall > 0 { each += Double(b.stall) / 60 }
        var waits = 0.0
        // A browser already at its minimum takes none of a narrower size: as
        // one that takes no size, nothing tells it from a late answer or a
        // dropped call before the cap.
        if !b.sizesStick || b.minWidth >= widthAtPress - 1 { waits += (GuardTiming.cap + 2 * WindowSteps.timeout) * Double(presses) }
        if b.dropsSizeCall != nil { waits += WindowSteps.timeout }
        // A dropped call a later press took over is waited for up to that press's cap, never sent again (review
        // of ce5bf39, F5): the press before's, it may yet land, late.
        if b.dropsSizeCall != nil, presses > 1 { waits += GuardTiming.cap }
        // A show or hide moves a browser whose sets land at once with its slide, frame by frame (`WindowGlide`): one that
        // only shows at the end of it that it can't go so narrow (it widens itself back) is found out after the slide.
        if !reduceMotion { waits += SidebarSlide.duration * Double(presses) }
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
    /// Four rests in a row with nothing changing end it.
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
        appCallsBefore = FakeApps.shared.calls.count
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
        appCallsBefore = FakeApps.shared.calls.count
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

/// Whether the guard expects a resize of the open pair at rest to fit the
/// pair again, from the rule itself and not from the app's
/// `SidebarGeometry.refitsAfterResize`: only a placement (both of the
/// browser's horizontal edges moved, or the browser on a display's whole
/// visible frame: Fill, a zoom, tiling) that would leave the sidebar beside it
/// further off the displays' visible frames than it was. A drag of one edge or
/// of a corner, and a move, stand (rule 3), wherever they leave the sidebar.
@MainActor
func placedPushingTheSidebarOff(from was: CGRect, to now: CGRect, width: CGFloat, side: SidebarSide, _ displays: [Display]) -> Bool {
    let resized = abs(now.width - was.width) >= 2 || abs(now.height - was.height) >= 2
    let leftMoved = abs(now.minX - was.minX) >= 2, rightMoved = abs(now.maxX - was.maxX) >= 2
    let onAWholeVisibleFrame = displays.contains { GuardFrames.same($0.visibleFrame, now) }
    guard resized, (leftMoved && rightMoved) || onAWholeVisibleFrame else { return false }
    let visible = displays.map { Display(frame: $0.visibleFrame, visibleFrame: $0.visibleFrame, scale: $0.scale) }
    func sidebar(beside b: CGRect) -> CGRect { CGRect(x: side == .left ? b.minX - width : b.maxX, y: b.minY, width: width, height: b.height) }
    return offScreen(sidebar(beside: now), visible) > offScreen(sidebar(beside: was), visible) + 1
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

    /// After the person placed the browser somewhere new while its sidebar was
    /// open (both horizontal edges moved, or the whole visible frame): the
    /// sidebar is never left further off the displays than it was (bug 3:
    /// Fill put the browser on the whole visible frame, and the sidebar was
    /// left off the screen). `before`: the browser's frame before, and the
    /// sidebar's width then.
    mutating func sidebarStaysOnScreen(before: CGRect, width: CGFloat, put: CGRect, _ step: String) {
        // A move (the size within 2 pt), or a drag of one horizontal edge or a corner, is the person's and stands
        // (rule 3), wherever it leaves the sidebar.
        let placed = (abs(put.minX - before.minX) >= 2 && abs(put.maxX - before.maxX) >= 2)
            || displays.contains { GuardFrames.same($0.visibleFrame, put) }
        guard rig.open, abs(put.width - before.width) >= 2 || abs(put.height - before.height) >= 2, placed else { return }
        let was = SidebarGeometry.strip(beside: before, width: width, side: rig.side)
        let now = SidebarGeometry.strip(beside: rig.fake.frame, width: rig.sidebarWidth, side: rig.side)
        let ds = displays.map(\.frame)
        // No further off than it was, or than the person put the window itself (the pair is their frame then).
        let allowed = max(SidebarGeometry.offScreen(was, displays: ds), SidebarGeometry.offScreen(put, displays: ds))
        if SidebarGeometry.offScreen(now, displays: ds) > allowed + 2 {
            problems.append("\(step): the sidebar left \(Int(SidebarGeometry.offScreen(now, displays: ds))) pt off the screen at \(now), was \(Int(SidebarGeometry.offScreen(was, displays: ds))) pt off at \(was)")
        }
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

    /// A refusal of a browser that moved and stopped short of the width it
    /// was asked (its minimum leaves the sidebar too little) is decided when
    /// it stops, not at the cap on a show (review of 596bc4e; at 9eb0125
    /// Brave against the screen's right edge sat squeezed for seconds): the
    /// note shows, and the window is back in its exact frame and stays there,
    /// within 0.5 s of the stop plus the modelled time of the way back's two
    /// calls (its place and its size), and a dropped one's wait. `start`:
    /// the frame it opened from.
    mutating func refusedPromptly(from start: CGRect, _ step: String) {
        let s = rig.samples
        guard !rig.open, let first = s.first, let noteAt = SidebarRig.noticeTimes.last(where: { $0 >= first.t - 1e-9 }) else { return }
        // The browser's last change before the note: where it stopped.
        let before = s.filter { $0.t <= noteAt + 1e-9 }
        guard let k = before.indices.dropFirst().last(where: { !GuardFrames.same(before[$0].browser, before[$0 - 1].browser) }) else { return }
        let stop = before[k]
        let asked = start.width - CGFloat(rig.instance.chosenWidth)
        guard stop.browser.width > asked + 2, stop.browser.width < start.width - 2 else { return }
        let b = rig.fake.behaviour
        var each = b.animation + b.animationDelay + b.animationHold + Double(b.sizeLag) / 30 + (b.timing == .atOnce ? 0 : b.lateBy)
        if b.animation == 0, b.enhancedUI, b.enhancedStuck { each += FakeBrowser.enhancedAnimation }
        if b.stall > 0 { each += Double(b.stall) / 60 }
        if b.dropsSizeCall != nil { each += WindowSteps.timeout }
        let allowed = 0.5 + 2 * each + 1.0 / 60
        if noteAt - stop.t > allowed {
            problems.append(String(format: "%@: stopped short at %.0f pt (asked %.0f), refused %.0f ms later, more than %.0f ms", step, Double(stop.browser.width),
                                   Double(asked), (noteAt - stop.t) * 1000, allowed * 1000))
        }
        guard let last = s.last, GuardFrames.same(last.browser, start) else { return }
        var back = last.t
        for x in s.reversed() {
            guard GuardFrames.same(x.browser, last.browser) else { break }
            back = x.t
        }
        if back - stop.t > allowed {
            problems.append(String(format: "%@: stopped short at %.0f pt, back in its frame %.0f ms later, more than %.0f ms", step, Double(stop.browser.width),
                                   (back - stop.t) * 1000, allowed * 1000))
        }
    }

    /// Quitting while the browser was hung held the app up no longer than
    /// quitting may (4 x `WindowSteps.timeout`), however long its calls wait.
    mutating func quitBound(_ step: String) {
        guard let took = rig.quitTook, took > GuardTiming.quit + 0.02 else { return }
        problems.append(String(format: "%@: quitting with the browser hung took %.0f ms, more than %.0f ms", step, took * 1000, GuardTiming.quit * 1000))
    }

    /// A press of the shortcut during a show or hide takes over the call in
    /// flight, but never sends it again: that call is the press before's,
    /// which the last press overrides (review of ce5bf39, F5: a hide sent a
    /// show's narrowing again, and macOS 27 narrowed the window further
    /// before the hide widened it). The first call a press during it sends
    /// (before any press after it) is never the size the last call before it
    /// asked, when the press before sent that one, and was a show or a hide.
    /// (A call from two presses back asked what this press asks again, show,
    /// hide, show, and a new width's close asks the frame a hide closes to:
    /// sending it again is this press's own call. Positions are not weighed:
    /// a show and a hide keep the window's origin on one side, so this
    /// press's own may be the same. A press while a refused show's window
    /// goes back is held until it is there: those calls go on, as asked.)
    mutating func noCallSentAgain(_ step: String) {
        let sent = rig.fake.sent
        func same(_ a: (t: Double, size: CGSize?, position: CGPoint?), _ b: (t: Double, size: CGSize?, position: CGPoint?)) -> Bool {
            if let x = a.size, let y = b.size { return abs(x.width - y.width) < 0.5 && abs(x.height - y.height) < 0.5 }
            return false
        }
        let presses = rig.pressedAt
        for i in presses.indices.dropFirst() {
            let p = presses[i], end = i + 1 < presses.count ? presses[i + 1].calls : sent.count
            guard presses[i - 1].toggles, p.calls > presses[i - 1].calls, p.calls < end,
                  !SidebarRig.noticeTimes.contains(where: { $0 >= presses[i - 1].t && $0 <= p.t }) else { continue }
            let last = sent[p.calls - 1], next = sent[p.calls]
            if same(last, next) {
                problems.append(String(format: "%@: the press at %.0f ms sent the size before it again (%@), %.0f ms later", step,
                                       (p.t - (rig.pressedAt.first?.t ?? p.t)) * 1000, "\(next.size.map { "\($0)" } ?? "")",
                                       (next.t - p.t) * 1000))
            }
        }
    }

    /// The panel never covers the browser's content (its body over the
    /// browser's frame, past the seam) for longer than 0.5 s plus the
    /// modelled animation, at any moment after a press: it is revealed only
    /// up to where the browser really is, so a slow or unmoving browser shows
    /// no panel over its content (the mini at ce5bf39: Brave at its minimum
    /// had the sidebar's list over its left 280 pt for the whole 3 s cap).
    mutating func panelNeverOver(_ step: String) {
        let b = rig.fake.behaviour
        let allowed = 0.5 + b.animation + b.animationDelay + b.animationHold + (b.animation == 0 && b.enhancedUI && b.enhancedStuck ? FakeBrowser.enhancedAnimation : 0)
        var since: Double?
        for x in rig.samples {
            guard x.over > 1 else { since = nil; continue }
            let from = since ?? x.t
            since = from
            if x.t - from > allowed {
                problems.append(String(format: "%@: the panel over the browser's content by %.0f pt for more than %.0f ms (browser %@)", step,
                                       Double(x.over), allowed * 1000, "\(x.browser)"))
                return
            }
        }
    }

    /// Nothing of a sidebar that is closing is drawn over its browser, and
    /// once ordered out it doesn't come back (Nick, 0.3.27: at the end of a
    /// hide the whole panel flashed over the browser for an instant; live on
    /// 3d5c1e4, 743 ms after the press, 220 ms after the slide had hidden it,
    /// for 70 ms until it was ordered out). From the last press, when it
    /// asked for the sidebar closed, and from a refusal's note: every change
    /// to what shows of the panel is checked, not only each tick, since the
    /// window server draws whatever the panel has between two ticks. While it
    /// closes the panel may show only up to the browser's real edge, as a
    /// slow browser leaves it (`SidebarSlide.seam`).
    mutating func nothingShowsOnceClosed(_ step: String) {
        // An open without a slide: the panel is shown only up to where the browser really is (`revealOpening`).
        if let x = rig.panelShows.first(where: { $0.opening && $0.ordered && $0.over > 1 }) {
            problems.append(String(format: "%@: %.0f pt of the sidebar drawn over the browser during an open without a slide", step, Double(x.over)))
            return
        }
        // Quitting or turning the sidebar off: from then on, nothing of it over the browser, and once out it stays out.
        if let k = rig.goneShows {
            var out = false
            for x in rig.panelShows[k...] {
                if x.over > 1 { problems.append(String(format: "%@: %.0f pt of the sidebar drawn over the browser as it was let go", step, Double(x.over))); return }
                if !x.ordered { out = true } else if out, x.shown > 0.5 { problems.append("\(step): the sidebar showed again after it was let go"); return }
            }
        }
        guard !rig.gone, !rig.open else { return }
        let shows = rig.panelShows
        let pressed = rig.pressedAt.last?.t ?? 0
        let note = SidebarRig.noticeTimes.last { $0 >= (rig.pressedAt.first?.t ?? 0) - 1e-9 }
        let from = !rig.askedOpen ? pressed : note
        guard let from else { return }
        let first = !rig.askedOpen ? rig.lastPressShows : min(rig.noticeShows ?? shows.count, shows.count)
        var out: Double?
        for x in shows[first...] {
            if x.over > 1 {
                problems.append(String(format: "%@: %.0f pt of the sidebar drawn over the browser %.0f ms into closing", step, Double(x.over), (x.t - from) * 1000))
                return
            }
            if !x.ordered { if out == nil { out = x.t }; continue }
            if let out, x.shown > 0.5 {
                problems.append(String(format: "%@: %.0f pt of the sidebar showed again %.0f ms after it was ordered out", step, Double(x.shown), (x.t - out) * 1000))
                return
            }
        }
    }

    /// The browser's enhanced UI is what it was before, once the app has
    /// stopped moving the window (`EnhancedUI`): set off right before the
    /// first set of a motion and back right after its last, never toggled per
    /// frame, never set at all when it was off, and nothing holds it. A
    /// browser hung when betterlink quit doesn't answer its flag's call: then
    /// its flip is still recorded, for the next launch to set back.
    mutating func flagRestored(_ step: String) {
        let apps = FakeApps.shared, pid = rig.pid
        let calls = apps.calls[min(rig.appCallsBefore, apps.calls.count)...]
        if let other = calls.first(where: { $0.pid != pid }) { problems.append("\(step): the enhanced UI of pid \(other.pid) touched, not this browser's") }
        if !rig.flagBefore, calls.contains(where: { $0.set != nil }) { problems.append("\(step): the enhanced UI was off, and was set: \(calls.map(\.set))") }
        // Off, back, off, back: never set off again before it was set back (a set back may be sent twice).
        var off = false
        for c in calls {
            guard let v = c.set else { continue }
            if !v, off, !apps.stuck.contains(pid) { problems.append("\(step): the enhanced UI set off twice in a row: \(calls.compactMap(\.set))"); break }
            off = !v
        }
        let offs = calls.filter { $0.set == false }.count
        if offs > 4 * max(1, rig.presses) { problems.append("\(step): the enhanced UI set off \(offs) times for \(rig.presses) press(es)") }
        if EnhancedUI.shared.isHeld(pid), !rig.instance.sliding { problems.append("\(step): the enhanced UI still held with nothing moving") }
        if apps.flag(pid) != rig.flagBefore {
            let recorded = EnhancedUI.shared.read().contains { $0.pid == pid && $0.was == rig.flagBefore }
            if !(rig.goneUnanswered && recorded) {
                problems.append("\(step): the enhanced UI is \(apps.flag(pid)), was \(rig.flagBefore)\(rig.goneUnanswered ? ", and not recorded for the next launch" : "")")
            }
        }
    }

    /// One smooth motion (Nick on 0.3.27: the browser's far edge animated in
    /// by the sidebar's width, then the whole browser slid): for a browser
    /// whose sets land at once (its enhanced UI on, as Nick's, but set off;
    /// or off), a show or hide with nothing else going on keeps the
    /// browser's far edge (away from the sidebar) where it was at every
    /// tick, within `farEdgeTolerance`; moves the browser in at least
    /// `smoothFrames` frames, as the slide does; and shows the sidebar
    /// exactly as far as the browser has made room, the pair always the
    /// frame it was. `pair`: the pair's frame (the browser's closed).
    mutating func oneSmoothMotion(pair: CGRect, _ step: String) {
        let s = rig.samples
        guard let first = s.first else { return }
        let left = rig.side == .left
        let far = { (r: CGRect) in left ? r.maxX : r.minX }
        // Where it was before the press (the first sample already has what went out with the press): the pair's far edge.
        let want = far(pair)
        // A window's first glide probes its sets with the size alone (`WindowGlide.probeStep`), for a tick or two.
        let probe = s.filter { abs(far($0.browser) - want) > Self.farEdgeTolerance }
        let probed = !probe.isEmpty && probe.allSatisfy { abs(far($0.browser) - want) <= WindowGlide.probeStep + 1 }
            && (probe.last!.t - probe.first!.t) <= Self.probeTicks / 120
        if !probed, let x = probe.first {
            problems.append(String(format: "%@: the browser's far edge at %.0f, %.0f pt from where it was, %.0f ms in (browser %@)", step,
                                   Double(far(x.browser)), Double(far(x.browser) - want), (x.t - first.t) * 1000, "\(x.browser)"))
            return
        }
        // No added latency (Nick): the first set goes out with the press, as the steps' first call always did,
        // not a tick or more later once the slide has moved a point.
        if let p = rig.pressedAt.first, p.calls < rig.fake.sent.count, rig.fake.sent[p.calls].t > p.t + 1e-9 {
            problems.append(String(format: "%@: the first set went out %.1f ms after the press", step, (rig.fake.sent[p.calls].t - p.t) * 1000))
        }
        let moving = Set(s.map { Int(($0.browser.width * 2).rounded()) }).count
        if moving < Self.smoothFrames { problems.append("\(step): the browser moved in \(moving) frames, fewer than \(Self.smoothFrames)") }
        if let x = s.first(where: { !$0.hidden && $0.shown > 0.5 && abs($0.shown + $0.browser.width - pair.width) > 2 }) {
            problems.append(String(format: "%@: the sidebar %.0f shown beside the browser %.0f wide, the pair %.0f, %.0f ms in", step, Double(x.shown),
                                   Double(x.browser.width), Double(pair.width), (x.t - first.t) * 1000))
        }
    }

    /// In the fake every set of a frame lands within the tick it was sent in,
    /// so the far edge holds exactly; live, a size and a position sent within
    /// one display refresh land as one frame (Nick's 27.2.1 and the mini's
    /// 26.5.2), except where a window can only widen toward the sidebar by
    /// moving first (against its screen's other edge): there each step is a
    /// position then a size, and the far edge can be one step in for one
    /// frame (16 pt at most at 120 ticks a second; measured live).
    static let farEdgeTolerance: CGFloat = 2
    /// A window's first glide (its sets not yet seen to land at once) sends
    /// its first frame's size alone: the far edge is `WindowGlide.probeStep`
    /// in for as long as that takes to show, at most this many ticks.
    static let probeTicks = 3.0
    /// The slide is 0.22 s, ticked 120 times a second: at least this many frames.
    static let smoothFrames = 12

    /// A change of the person's to a closed window stands: the window is
    /// where they put it, the sidebar still closed, and no note more than
    /// `notes` (review N1).
    mutating func closedStands(_ f: CGRect, notes: Int, _ step: String) {
        personDid(f, step)
        if rig.open { problems.append("\(step): the sidebar opened, though nobody pressed anything") }
        if SidebarRig.notices.count != notes {
            problems.append("\(step): \(SidebarRig.notices.count - notes) more note(s): \(SidebarRig.notices.map(\.0))")
        }
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
        case 6: return [(r.double(0...0.8), r.bool(0.3) ? .quitHung : .quit)]
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

    /// Whether the browser can give the sidebar its least width out of
    /// `frame`, and answers in time to: a browser that takes more than a
    /// second over each call may run past the cap on a show (`GuardTiming.cap`),
    /// and then its window gets its frame back, closed, which is as right.
    func canOpen(from frame: CGRect) -> Bool {
        behaviour.sizesStick && max(behaviour.minWidth, 1) <= frame.width - SidebarGeometry.widths.lowerBound
            && (behaviour.timing == .atOnce || behaviour.lateBy <= 1)
    }

    /// The window resized by the person from its right and bottom edges, its
    /// top left kept: what a browser does with a size it was asked, so only
    /// betterlink's knowing that it asked nothing tells them apart (review N1).
    /// Pressed more than once, a browser that drops a call: the call it dropped may be the press before's,
    /// which a later press takes over and waits for up to its cap, never sending it again (review of ce5bf39,
    /// F5): an open is then refused at the cap, as one the browser didn't answer.
    func dropTakenOver(_ rig: SidebarRig) -> Bool { rig.presses > 1 && behaviour.dropsSizeCall != nil }

    func resizedByHand(_ f: CGRect, round: Int) -> CGRect {
        let dw: CGFloat = round == 0 ? -40 : 30, dh: CGFloat = round == 0 ? 0 : -20
        let w = max(200, behaviour.minWidth, f.width + dw)
        return CGRect(x: f.minX, y: f.minY - dh, width: w, height: f.height + dh)
    }

    /// A browser whose sets land at once once its enhanced UI is off, with
    /// nothing else in the way: what `oneSmoothMotion` holds to.
    var landsAtOnce: Bool {
        let b = behaviour
        return b.timing == .atOnce && b.animation == 0 && b.sizeLag == 0 && b.stall == 0 && b.dropsSizeCall == nil && !b.positionOnly
            && b.revertReads == 0 && !b.tiler && !b.widensBack && !b.hangs && !(b.enhancedUI && b.enhancedStuck) && !reduceMotion
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
            check.noCallSentAgain(show)
            check.panelNeverOver(show)
            check.nothingShowsOnceClosed(show)
            check.flagRestored(show)
            if rig.gone {
                // Quit or turned off while it was carried out: the window has the frame it started in
                // (unless its browser wasn't answering then: see `goneUnanswered`).
                let step = "\(show), \(showDuring.last.map { "\($0.what)" } ?? "") while it was carried out"
                check.quitBound(step)
                if !rig.goneUnanswered {
                    check.either([{ $0.hidden(from: start, sidebar: 0, wasOpen: false, step) },
                                  { $0.hidden(from: start, sidebar: 0, wasOpen: true, step) }])
                }
                break
            }
            if landsAtOnce, showDuring.isEmpty, !(round == 0 && bySettle), rig.open, rig.presses == 1, rig.sidebarWidth >= CGFloat(rig.instance.chosenWidth) - 1 {
                check.oneSmoothMotion(pair: start, show)
            }
            if let put = rig.personPut, rig.personAtRest,
               placedPushingTheSidebarOff(from: rig.personFrom, to: put, width: rig.personWidth, side: side, displays) {
                check.shown(from: put, mustOpen: canOpen(from: put), offFrom: put, "\(show), resized by the person once it was open")
            } else if let put = rig.personPut {
                check.personDid(put, "\(show), moved or resized by the person while it was carried out")
            } else if let put = rig.tilerPut {
                // A tiling app put the window back once betterlink was done: another app's change, which stands
                // (rule 3), or which betterlink answered by the rules.
                let step = "\(show), put back by a tiling app"
                check.either([{ $0.personDid(put, step) }, { $0.shown(from: start, mustOpen: false, step) }])
            } else if rig.askedOpen {
                // Pressed more than once, it may have closed meanwhile, on screen (rule 4), and opened from there.
                let onScreen = pairFrame(browser: start, sidebar: 0, side: side)
                let must = { (from: CGRect) in canOpen(from: from) && !dropTakenOver(rig) }
                check.either([start, onScreen].map { from in { $0.shown(from: from, mustOpen: must(from), offFrom: start, show) } })
                if rig.presses == 1 { check.refusedPromptly(from: start, show) }
            } else {
                let step = "\(show), pressed again while it was carried out"
                check.either([{ $0.hidden(from: start, sidebar: 0, wasOpen: false, step) },
                              { $0.hidden(from: start, sidebar: 0, wasOpen: true, step) }])
            }
            if !rig.open, rig.askedOpen, rig.personPut == nil {
                // Refused: the window is the person's again. Resized from its right and bottom edges, it stays so
                // and the sidebar stays closed with no second note (review N1); moved to a fresh frame, it stays there.
                let notes = SidebarRig.notices.count
                let resized = resizedByHand(rig.fake.frame, round: round)
                rig.personSets(resized)
                check.closedStands(resized, notes: notes, "\(show), refused, then the person resizes the window from its right and bottom edges")
                var f = rig.fake.frame
                f.origin.x += round == 0 ? -37 : 23
                rig.personSets(f)
                check.closedStands(f, notes: notes, "\(show), refused, then the person moves the window")
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
                        check.noCallSentAgain(step)
                        check.panelNeverOver(step)
                        check.nothingShowsOnceClosed(step)
                        check.flagRestored(step)
                        if rig.askedOpen {
                            check.shown(from: pair, mustOpen: canOpen(from: pair), offFrom: before, step)
                            if p == nil { check.refusedPromptly(from: pair, step) }
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
                        let w = rig.sidebarWidth
                        rig.personSets(f)
                        // Placed anew (both horizontal edges moved) pushing the sidebar off the screen: the pair
                        // fits again in the person's frame (rules 2 and 3); a drag of one edge, or any other
                        // resize, stands as they left it (rule 3).
                        if placedPushingTheSidebarOff(from: before, to: f, width: w, side: side, displays) {
                            check.shown(from: f, mustOpen: canOpen(from: f), offFrom: f, step)
                        } else {
                            check.personDid(f, step)
                        }
                        // For a browser that answers what it is asked (no tiling app putting it back, not busy or
                        // stalling): with those, the re-fit can be overtaken, and the person's frame then stands.
                        if !behaviour.tiler, behaviour.stall == 0, behaviour.timing == .atOnce {
                            check.sidebarStaysOnScreen(before: before, width: w, put: f, step)
                        }
                    case .dragEdge(let delta):
                        let pair = rig.pair
                        rig.personDragsEdge(by: delta)
                        check.timely(step)
                        check.flagRestored(step)
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
                let pair = pairFrame(browser: b, sidebar: w, side: side)
                // Its far edge kept: the pair isn't moved back on screen at closing.
                let farKept = side == .left ? abs(pair.maxX - b.maxX) < 1 : abs(pair.minX - b.minX) < 1
                if landsAtOnce, hideDuring.isEmpty, farKept, !rig.open, b.width > behaviour.minWidth + 1 || behaviour.minWidth == 0 {
                    check.oneSmoothMotion(pair: pair, hide)
                }
                check.timely(hide)
                check.noCallSentAgain(hide)
                check.panelNeverOver(hide)
                check.nothingShowsOnceClosed(hide)
                check.flagRestored(hide)
                if rig.gone {
                    check.quitBound(hide)
                    if !rig.goneUnanswered {
                        check.hidden(from: b, sidebar: w, wasOpen: true, "\(hide), \(hideDuring.last.map { "\($0.what)" } ?? "") while it was carried out")
                    }
                    break
                }
                if let put = rig.personPut {
                    check.personDid(put, "\(hide), moved or resized by the person while it was carried out")
                } else if let put = rig.tilerPut {
                    let step = "\(hide), put back by a tiling app"
                    check.either([{ $0.personDid(put, step) }, { $0.hidden(from: b, sidebar: w, wasOpen: true, step) }])
                } else if rig.askedOpen {
                    let pair = pairFrame(browser: b, sidebar: w, side: side)
                    check.shown(from: pair, mustOpen: canOpen(from: pair) && !dropTakenOver(rig), offFrom: b, "\(hide), pressed again while it was carried out")
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
            if !rig.open, !rig.gone, check.problems.isEmpty {
                // Hidden (late answers and all): the window is the person's. Resized from its right and bottom
                // edges, it stays so, closed, with no note (review N1, the same after a hide).
                let notes = SidebarRig.notices.count
                let resized = resizedByHand(rig.fake.frame, round: round)
                rig.personSets(resized)
                check.closedStands(resized, notes: notes, "\(hide), then the person resizes the closed window from its right and bottom edges")
            }
            if !check.problems.isEmpty { break }
        }
        if Self.verbose {
            print("SidebarGuard case: \(self)\n  \(check.problems.joined(separator: "\n  "))")
            for h in rig.fake.history { print("  \(h.byPerson ? "person" : "app/browser") \(h.frame)") }
            for c in rig.fake.sent { print(String(format: "  sent at %.1f ms: ", c.t * 1000) + "\(c.size.map { "size \($0)" } ?? "")\(c.position.map { "position \($0)" } ?? "")") }
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
        DragTrace.echo = only != nil ? { print("trace: \($0)") } : nil
        defer { DragTrace.echo = nil }
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

    /// Review of 596bc4e, F1: a refusal is remembered for nothing but that
    /// press. Pressed again, the browser is asked again (it may have been
    /// resized, or have stopped only for a moment), and refused again by
    /// what it does then: the window back in its frame, a second note.
    @Test func aPressAfterARefusalAsksTheBrowserAgain() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let start = CGRect(x: 1256, y: 0, width: 800, height: 1259)
        for b in [BrowserBehaviour(minWidth: 615), BrowserBehaviour(minWidth: 615, animation: 0.25)] {
            for side in SidebarSide.allCases {
                let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: b)
                rig.toggle()
                #expect(!rig.open && SidebarRig.notices.count == 1, "\(b) \(side): open \(rig.open), notes \(SidebarRig.notices.map(\.0))")
                let calls = rig.fake.setCalls
                rig.toggle()
                let step = "\(b) \(side), pressed again"
                #expect(rig.fake.setCalls > calls, "\(step): the browser wasn't asked")
                #expect(!rig.open && GuardFrames.same(rig.fake.frame, start), "\(step): open \(rig.open), at \(rig.fake.frame)")
                #expect(SidebarRig.notices.map(\.0) == [.noRoom, .noRoom], "\(step): notes \(SidebarRig.notices.map(\.0))")
                var check = RuleCheck(rig, displays: [screen])
                check.refusedPromptly(from: start, step)
                check.timely(step)
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
            }
        }
    }

    /// Review of 596bc4e, F1: on macOS 27 a narrowing can stand still partway
    /// (the reviewer: 2056 to 1900, still for 250 ms, then on to 1776). That
    /// is no minimum: the sidebar opens at its width, with no note, and a
    /// later press is not refused by it.
    @Test func aHoldPartwayThroughAnAnimationIsNoMinimum() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        let brave = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        for hold in [0.16, 0.25, 0.3] {
            for side in SidebarSide.allCases {
                let b = BrowserBehaviour(animation: 0.2, animationHold: hold, holdAt: 0.5)
                let rig = SidebarRig(displays: [screen], frame: brave, side: side, width: 280, behaviour: b)
                rig.toggle()
                let step = "\(b) \(side)"
                var check = RuleCheck(rig, displays: [screen])
                check.timely(step)
                check.shown(from: brave, mustOpen: true, step)
                #expect(SidebarRig.notices.isEmpty, "\(step): notes \(SidebarRig.notices.map(\.0))")
                #expect(abs(rig.sidebarWidth - 280) < 2, "\(step): sidebar \(rig.sidebarWidth)")
                let w = rig.sidebarWidth, browser = rig.fake.frame
                rig.toggle()
                check.hidden(from: browser, sidebar: w, wasOpen: true, "\(step): hide")
                rig.toggle()
                check.shown(from: brave, mustOpen: true, "\(step): shown again")
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
            }
        }
    }

    /// Review of ce5bf39, F5: macOS 27 holds a show's narrowing partway
    /// (still, short of the width asked), and the shortcut is pressed again
    /// before the show has sent its size once more to check the hold. The
    /// hide takes over the show's call in flight, but never sends it again:
    /// the last press wins. After the press the window is never narrower
    /// than when it was pressed, no size of the show's is sent, and the
    /// window ends where it began, closed.
    @Test func aHideNeverSendsTheShowsCallAgain() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        let brave = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        // The size animated over 0.2 s, still from 0.1 s to 0.4 s: the show would check it at 0.25 s. The
        // show's size is the second animation, after its glide's probe (`WindowGlide`), which finds the sets animated.
        let b = BrowserBehaviour(animation: 0.2, animationHold: 0.3, holdAt: 0.5, holdsFirst: 2)
        for side in SidebarSide.allCases {
            // The show's size goes out once its glide's probe, sent when the slide has moved the frame a point
            // (about 25 ms in), has been seen not to land at once (`WindowGlide.instant`): about 85 ms after the press.
            for at in [0.12, 0.15, 0.2].map({ $0 + 0.1 }) {
                let rig = SidebarRig(displays: [screen], frame: brave, side: side, width: 280, behaviour: b)
                rig.toggle(during: [(at, .press)])
                let step = "\(side), pressed again \(Int(at * 1000)) ms into the show"
                guard rig.pressedAt.count == 2 else { Issue.record("\(step): \(rig.pressedAt.count) presses"); continue }
                let press = rig.pressedAt[1]
                let shows = Set(rig.fake.sent.prefix(press.calls).compactMap { $0.size.map { Int($0.width) } })
                let after = rig.fake.sent.dropFirst(press.calls).compactMap(\.size)
                #expect(!after.contains { shows.contains(Int($0.width)) && $0.width < brave.width - 1 }, "\(step): the show's size sent again: \(after)")
                let pressedWidth = rig.samples.last { $0.t < press.t }?.browser.width ?? 0
                let least = rig.samples.filter { $0.t >= press.t }.map(\.browser.width).min() ?? 0
                #expect(least >= pressedWidth - 1, "\(step): \(Int(pressedWidth)) wide when pressed, then \(Int(least))")
                #expect(!rig.open && GuardFrames.same(rig.fake.frame, brave), "\(step): open \(rig.open), the window at \(rig.fake.frame)")
                var check = RuleCheck(rig, displays: [screen])
                check.timely(step)
                check.noCallSentAgain(step)
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
            }
        }
    }

    /// Review of ce5bf39, F5, the same for quitting and turning the sidebar
    /// off during an open (`AXWindow.placeNow`): the window is given its
    /// frame back with no size of the open's sent again, so none of the
    /// bound is spent on it.
    @Test func quittingDuringAnOpenSendsNoStaleSize() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        let brave = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        let b = BrowserBehaviour(animation: 0.2, animationHold: 0.3, holdAt: 0.5)
        for side in SidebarSide.allCases {
            for what in [SidebarRig.During.quit, .turnOff] {
                for at in [0.12, 0.15, 0.2] {
                    let rig = SidebarRig(displays: [screen], frame: brave, side: side, width: 280, behaviour: b)
                    rig.toggle(during: [(at, what)])
                    let step = "\(side), \(what) \(Int(at * 1000)) ms into the open"
                    guard let quit = rig.goneAt, let opened = rig.pressedAt.first else { Issue.record("\(step): not gone"); continue }
                    let open = Set(rig.fake.sent[opened.calls..<quit.calls].compactMap { $0.size.map { Int($0.width) } })
                    let after = rig.fake.sent.dropFirst(quit.calls).compactMap(\.size)
                    #expect(!after.contains { open.contains(Int($0.width)) && $0.width < brave.width - 1 }, "\(step): the open's size sent again: \(after)")
                    #expect(rig.gone && GuardFrames.same(rig.fake.frame, brave), "\(step): the window at \(rig.fake.frame)")
                }
            }
        }
    }

    /// Live on the mini at ce5bf39: Brave at its own minimum (615 pt),
    /// against the screen's right edge or free on screen, the sidebar on the
    /// left at 280, the shortcut pressed. The browser can't go narrower, so
    /// it never moves: the sidebar's list was drawn over the browser's left
    /// 280 pt for the whole 3 s cap, then the sidebar closed. The panel is
    /// never over the browser's content. Once this window's browser has been
    /// seen to stop at 615 (an open from 800 pt, refused when it stopped),
    /// a press asks the browser again and, the window not moving, is refused
    /// for want of room within 0.5 s plus its calls, not at the cap.
    @Test func aWindowAtItsBrowsersMinimum() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        for x in [CGFloat(2056 - 615), 800] {
            for b in [BrowserBehaviour(minWidth: 615), BrowserBehaviour(minWidth: 615, animation: 0.25)] {
                for seen in [false, true] {
                    let at = CGRect(x: x, y: 0, width: 615, height: 1259)
                    let step = "\(x == 2056 - 615 ? "against the right edge" : "free"), \(b), \(seen ? "its minimum seen" : "nothing seen")"
                    let rig: SidebarRig
                    if seen {
                        let wide = CGRect(x: at.maxX - 800, y: 0, width: 800, height: 1259)
                        rig = SidebarRig(displays: [screen], frame: wide, side: .left, width: 280, behaviour: b)
                        rig.toggle()
                        #expect(!rig.open && GuardFrames.same(rig.fake.frame, wide), "\(step): from 800, open \(rig.open), at \(rig.fake.frame)")
                        rig.personSets(at)
                    } else {
                        rig = SidebarRig(displays: [screen], frame: at, side: .left, width: 280, behaviour: b)
                    }
                    let notes = SidebarRig.notices.count
                    rig.toggle()
                    #expect(!rig.open && GuardFrames.same(rig.fake.frame, at), "\(step): open \(rig.open), at \(rig.fake.frame)")
                    let over = rig.samples.map(\.over).max() ?? 0
                    #expect(over <= 1, "\(step): the panel over the browser's content by \(Int(over)) pt")
                    let pressed = rig.pressedAt.first?.t ?? 0
                    let note = SidebarRig.noticeTimes.dropFirst(notes).first
                    #expect(SidebarRig.notices.dropFirst(notes).map(\.0).first == (seen ? .noRoom : .noSize), "\(step): notes \(SidebarRig.notices.dropFirst(notes).map(\.0))")
                    if seen {
                        let allowed = 0.5 + 2 * (b.animation + b.animationDelay)
                        #expect(note.map { $0 - pressed <= allowed } == true,
                                "\(step): refused \(note.map { Int(($0 - pressed) * 1000) } ?? -1) ms after the press, more than \(Int(allowed * 1000))")
                    }
                    var check = RuleCheck(rig, displays: [screen])
                    check.panelNeverOver(step)
                    #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                }
            }
        }
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
                // Held still `still`, its size sent once more (a hold partway through an animation is no minimum), held again.
                #expect(s[refused].t - stopped <= 2 * WindowSteps.still + 0.05, "\(b): refused \(Int((s[refused].t - stopped) * 1000)) ms after the browser stopped at \(Int(w))")
            } else {
                Issue.record("\(b): never refused")
            }
            // From the stop: before it, the sidebar slides in beside the browser narrowing with it (`WindowGlide`).
            let stop = s.firstIndex(where: \.hidden).flatMap { r in s[..<r].lastIndex { abs($0.browser.width - s[max(0, r - 1)].browser.width) >= 0.5 }.map { s[$0 + 1].t } } ?? 0
            let squeezed = Double(s.filter { $0.t >= stop && $0.shown > 1 && $0.browser.width < start.width - 2 }.count) / 120
            #expect(squeezed <= 2 * WindowSteps.still + 0.05, "\(b): the sidebar shown beside the squeezed window for \(Int(squeezed * 1000)) ms after it stopped")
            var check = RuleCheck(rig, displays: [screen])
            check.timely("refused")
            #expect(check.problems.isEmpty, "\(b): \(check.problems)")
            // One note, saying why, over the window's frame.
            #expect(SidebarRig.notices.map(\.0) == [.noRoom] && SidebarRig.notices.first.map { GuardFrames.same($0.1, start) } == true,
                    "\(b): notes \(SidebarRig.notices)")

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

    /// At 9eb0125 Brave (its least width 615) against the screen's right
    /// edge at 800 pt stayed narrowed for seconds before it was put back.
    /// A browser that moves and stops short of the width asked, leaving the
    /// sidebar less than its least, is refused when it stops: the note at
    /// once, the window back in its exact frame within 0.5 s plus the
    /// modelled time of the way back, never at the cap on a show. Either
    /// side, browsers that take a call at once, animate (starting late too),
    /// answer late or busy, land a size some reads later, or widen back.
    @Test func aBrowserThatStopsShortIsRefusedWhenItStops() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let start = CGRect(x: 1256, y: 0, width: 800, height: 1259)
        let behaviours = [BrowserBehaviour(minWidth: 615), BrowserBehaviour(minWidth: 615, animation: 0.25),
                          BrowserBehaviour(minWidth: 615, animation: 0.25, animationDelay: 0.3), BrowserBehaviour(timing: .late, lateBy: 0.3, minWidth: 615),
                          BrowserBehaviour(timing: .busy, lateBy: 0.3, minWidth: 615), BrowserBehaviour(minWidth: 615, sizeLag: 2),
                          BrowserBehaviour(minWidth: 615, widensBack: true)]
        for b in behaviours {
            for side in SidebarSide.allCases {
                let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: b)
                rig.toggle()
                let step = "\(b) \(side)"
                var check = RuleCheck(rig, displays: [screen])
                check.refusedPromptly(from: start, step)
                check.timely(step)
                #expect(!rig.open && GuardFrames.same(rig.fake.frame, start), "\(step): open \(rig.open), at \(rig.fake.frame)")
                #expect(SidebarRig.notices.map(\.0) == [.noRoom], "\(step): notes \(SidebarRig.notices.map(\.0))")
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
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
    /// stopped waiting was refused with the "didn't make room" note, and its
    /// late answer then narrowed the window with the sidebar closed: full
    /// screen, sidebar left, 1.3 s late and later ended at 0, 0, 1776, 1259,
    /// 280 pt lost. A show or hide is capped (`GuardTiming.cap`), every call
    /// of it included, and ends by sending its final frame once more, after
    /// all the others: a browser that answers within the cap opens; one
    /// slower gets its exact frame back, closed, with the note, and never
    /// opens later by itself. A hide whose calls land late ends in the
    /// pair's frame. No width is lost either way. (The fake's late browser
    /// is late with sizes only, its busy one with every call.)
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
                    let step = "\(b) \(side): show"
                    check.timely(step)
                    if late <= 1 || rig.open {
                        check.shown(from: start, mustOpen: true, step)
                        #expect(SidebarRig.notices.isEmpty, "\(step): notes \(SidebarRig.notices.map(\.0)), though it opened")
                    } else {
                        // Past the cap: its frame back exactly, closed, and one note saying why.
                        check.shown(from: start, mustOpen: false, step)
                        #expect(SidebarRig.notices.map(\.0) == [.noSize], "\(step): notes \(SidebarRig.notices.map(\.0))")
                    }
                    // Two calls (the sidebar on the left: a size, then a place) each 1.5 s late or more run past the cap.
                    if late >= 1.5, side == .left, timing == .busy { #expect(!rig.open, "\(step): opened, though the browser answers each call \(late) s late") }
                    // Nothing more happens by itself: it neither opens nor moves later.
                    let frame = rig.fake.frame, open = rig.open
                    rig.rest()
                    #expect(rig.open == open && GuardFrames.same(rig.fake.frame, frame), "\(step): later open \(rig.open), at \(rig.fake.frame)")
                    if rig.open {
                        let w = rig.sidebarWidth, browser = rig.fake.frame
                        rig.toggle()
                        check.timely("\(b) \(side): hide")
                        check.hidden(from: browser, sidebar: w, wasOpen: true, "\(b) \(side): hide")
                    }
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

    /// Review of 4c6cabb, N1: a browser that takes no size is refused with
    /// the "didn't make room" note; the person then resizes the closed window
    /// from its right or bottom edge, its top left where it was. That was
    /// taken for the browser's late answer to the open: betterlink opened the
    /// sidebar, was refused again, put the window back over the person's
    /// resize and showed a second note. The person's frame stands, closed,
    /// with the one note. From the refusal on, the browser takes what it is
    /// asked at once, so anything betterlink sends would show.
    @Test func aPersonsResizeAfterARefusalStands() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let start = CGRect(x: 0, y: 0, width: 1028, height: 1259)
        let slow = [BrowserBehaviour(positionOnly: true), BrowserBehaviour(timing: .late, lateBy: 3), BrowserBehaviour(timing: .busy, lateBy: 3),
                    BrowserBehaviour(timing: .late, lateBy: 30)]
        for b in slow {
            for side in SidebarSide.allCases {
                for (dw, dh) in [(CGFloat(-40), CGFloat(0)), (30, 0), (0, -40), (0, 30)] {
                    let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: b)
                    rig.toggle()
                    let step = "\(b) \(side), resized by \(Int(dw)), \(Int(dh))"
                    #expect(!rig.open && GuardFrames.same(rig.fake.frame, start), "\(step): open \(rig.open), at \(rig.fake.frame)")
                    #expect(SidebarRig.notices.map(\.0) == [.noSize], "\(step): notes \(SidebarRig.notices.map(\.0))")
                    rig.fake.behaviour = BrowserBehaviour()
                    let at = rig.fake.frame
                    let resized = CGRect(x: at.minX, y: at.minY - dh, width: at.width + dw, height: at.height + dh)
                    rig.personSets(resized)
                    var check = RuleCheck(rig, displays: [screen])
                    check.closedStands(resized, notes: 1, step)
                    #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                }
            }
        }
    }

    /// N1's class, after a hide: a browser that turned slow is hidden (its
    /// calls landing up to 3 s late, past betterlink's waits), and the
    /// person then resizes the closed window from its right or bottom edge.
    /// Their frame stands, closed, no note.
    @Test func aPersonsResizeAfterALateHideStands() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let start = CGRect(x: 0, y: 0, width: 1028, height: 1259)
        let slow = [BrowserBehaviour(positionOnly: true), BrowserBehaviour(timing: .late, lateBy: 1.3), BrowserBehaviour(timing: .late, lateBy: 3),
                    BrowserBehaviour(timing: .busy, lateBy: 3)]
        for b in slow {
            for side in SidebarSide.allCases {
                for (dw, dh) in [(CGFloat(-40), CGFloat(0)), (30, 0), (0, -40), (0, 30)] {
                    let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: BrowserBehaviour())
                    rig.toggle()
                    #expect(rig.open, "\(side): didn't open")
                    rig.fake.behaviour = b
                    rig.toggle()
                    let step = "\(b) \(side), hidden, then resized by \(Int(dw)), \(Int(dh))"
                    rig.fake.behaviour = BrowserBehaviour()
                    let at = rig.fake.frame
                    let resized = CGRect(x: at.minX, y: at.minY - dh, width: at.width + dw, height: at.height + dh)
                    rig.personSets(resized)
                    var check = RuleCheck(rig, displays: [screen])
                    check.closedStands(resized, notes: 0, step)
                    #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                }
            }
        }
    }

    /// N1's class, after a new width (`refit`: closed and opened again) a
    /// browser that turned slow answers late: the person then resizes the
    /// window from its right or bottom edge. Their frame stands, and nothing
    /// opens, closes or shows a note because of it.
    @Test func aPersonsResizeAfterALateNewWidthStands() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let start = CGRect(x: 0, y: 0, width: 1028, height: 1259)
        let slow = [BrowserBehaviour(positionOnly: true), BrowserBehaviour(timing: .late, lateBy: 1.3), BrowserBehaviour(timing: .late, lateBy: 3),
                    BrowserBehaviour(timing: .busy, lateBy: 3)]
        for b in slow {
            for side in SidebarSide.allCases {
                for (dw, dh) in [(CGFloat(-40), CGFloat(0)), (30, 0), (0, -40), (0, 30)] {
                    let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: BrowserBehaviour())
                    rig.toggle()
                    #expect(rig.open, "\(side): didn't open")
                    rig.fake.behaviour = b
                    rig.carry(.width(360), during: [])
                    let step = "\(b) \(side), the width set to 360, then resized by \(Int(dw)), \(Int(dh))"
                    var check = RuleCheck(rig, displays: [screen])
                    check.timely(step)
                    rig.fake.behaviour = BrowserBehaviour()
                    let open = rig.open, notes = SidebarRig.notices.count
                    let at = rig.fake.frame
                    let resized = CGRect(x: at.minX, y: at.minY - dh, width: at.width + dw, height: at.height + dh)
                    rig.personSets(resized)
                    check.personDid(resized, step)
                    #expect(rig.open == open, "\(step): open \(open) before the resize, \(rig.open) after")
                    #expect(SidebarRig.notices.count == notes, "\(step): notes \(SidebarRig.notices.map(\.0)), \(notes) before the resize")
                    #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                }
            }
        }
    }

    /// macOS 27's animation can begin late (no frame on screen changes for
    /// a while after the set): a call whose window hasn't moved yet hasn't
    /// started, and is waited for, never taken as refused or done.
    @Test func macOS27AnimationsThatStartLate() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        let brave = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        let half = CGRect(x: 1028, y: 0, width: 1028, height: 1290)
        for delay in [0.05, 0.15, 0.3, 0.45] {
            for side in SidebarSide.allCases {
                for w in [brave, half] {
                    for b in [BrowserBehaviour(animation: 0.25, animationDelay: delay), BrowserBehaviour(minWidth: 615, animation: 0.25, animationDelay: delay)] {
                        run(GuardCase(displays: [screen], window: w, side: side, width: 280, behaviour: b, reduceMotion: false, actions: [[.dragEdge(-60)], [.resizeBrowser(left: 40, right: 0)]]))
                    }
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
                let rigs = frames.enumerated().map { SidebarRig(displays: [screen], frame: $1, side: side, width: 280, behaviour: BrowserBehaviour(), freshApps: $0 == 0) }
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

    /// Quitting, or turning the sidebar off, while a browser is hung (every
    /// Accessibility call to it waits out its time, 1 s as betterlink sets
    /// it): the app is held up no longer than quitting may be
    /// (`GuardTiming.quit`), however many windows it has. What misses that
    /// is left as it is, the person's, and nothing is sent to it again.
    /// Quitting with many hung browsers before it, and a window mid-show
    /// whose own hold of its browser's flag is the last (the hold loop ran
    /// out of time before its browser): setting that flag back stays within
    /// the bound too, or is left on record for the next launch (review F4 of
    /// 1df43a3: its release could send up to 4 calls of 0.2 s after the
    /// moves, past 2.4 s).
    @Test func quittingSetsEveryFlagBackWithinTheBound() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        for side in SidebarSide.allCases {
            // Ten idle browsers, hung at quit (each hold's read waits out 0.2 s), then the one mid-show.
            let rigs = (0..<11).map { k in
                SidebarRig(displays: [screen], frame: CGRect(x: CGFloat(k) * 60, y: 0, width: 1200, height: 1259), side: side, width: 280,
                           behaviour: BrowserBehaviour(enhancedUI: true), pid: SidebarRig.browserPid + 100 + pid_t(k), freshApps: k == 0)
            }
            for r in rigs.dropLast() { r.toggle(); #expect(r.open, "\(side): didn't open") }
            let last = rigs.last!
            last.toggle(within: 0.05)
            #expect(EnhancedUI.shared.isHeld(last.pid), "\(side): the show's hold isn't on")
            var clock = (rigs.map(\.now).max() ?? 0) + 10
            let began = clock
            for r in rigs {
                r.fake.behaviour.hangs = true
                r.fake.now = { clock }
                r.fake.wait = { clock += $0 }
                r.instance.clock = { clock }
                r.instance.pause = { clock += $0 }
            }
            SidebarController.shared.giveSpaceBack(of: rigs.map(\.instance), clock: { clock }, pause: { clock += $0 })
            #expect(clock - began <= GuardTiming.quit + 0.02, "\(side): quitting waited \(Int((clock - began) * 1000)) ms")
            // Its flag: set back, or on record for the next launch.
            let back = FakeApps.shared.flag(last.pid)
            #expect(back || EnhancedUI.shared.read().contains { $0.pid == last.pid && $0.was }, "\(side): the flag left off and not recorded")
            #expect(!EnhancedUI.shared.isHeld(last.pid))
        }
    }

    @Test func quittingWithAHungBrowserStaysWithinTheBound() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let frames = (0..<6).map { CGRect(x: CGFloat($0) * 150, y: 0, width: 1200, height: 1259) }
        for side in SidebarSide.allCases {
            for count in [1, 6] {
                let rigs = frames.prefix(count).enumerated().map { SidebarRig(displays: [screen], frame: $1, side: side, width: 280, behaviour: BrowserBehaviour(), freshApps: $0 == 0) }
                for r in rigs { r.toggle(); #expect(r.open, "\(side): didn't open") }
                var clock = (rigs.map(\.now).max() ?? 0) + 10
                let began = clock
                let before = rigs.map(\.fake.frame)
                for r in rigs {
                    r.fake.behaviour.hangs = true
                    r.fake.now = { clock }
                    r.fake.wait = { clock += $0 }
                    r.instance.clock = { clock }
                    r.instance.pause = { clock += $0 }
                }
                SidebarController.shared.giveSpaceBack(of: rigs.map(\.instance), clock: { clock }, pause: { clock += $0 })
                #expect(clock - began <= GuardTiming.quit + 0.02, "\(side), \(count) windows: quitting waited \(Int((clock - began) * 1000)) ms")
                for (r, f) in zip(rigs, before) { #expect(GuardFrames.same(r.fake.frame, f), "\(side): a hung window moved to \(r.fake.frame)") }
                // Turned off, one window at a time (the browser no longer attached): each within the bound too.
                let one = SidebarRig(displays: [screen], frame: frames[0], side: side, width: 280, behaviour: BrowserBehaviour())
                one.toggle()
                one.fake.behaviour.hangs = true
                let t0 = one.now
                one.instance.close(closed: false)
                #expect(one.now - t0 <= GuardTiming.quit + 0.02, "\(side): turning off waited \(Int((one.now - t0) * 1000)) ms")
            }
        }
    }

    /// Review of 596bc4e, F2: turning the sidebar off gives every window
    /// back in one batch, then lets each go (`SidebarController.stop`: the
    /// tracker stops, and each window is closed, not gone). A window whose
    /// browser missed a call in the batch is sent nothing more when it is let
    /// go: the batch and the closes together stay within quitting's bound,
    /// however many windows the hung browser has.
    @Test func turningOffWithAHungBrowserStaysWithinTheBound() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        for side in SidebarSide.allCases {
            let rigs = (0..<12).map { SidebarRig(displays: [screen], frame: CGRect(x: CGFloat($0) * 60, y: 0, width: 1200, height: 1259), side: side,
                                                 width: 280, behaviour: BrowserBehaviour(), freshApps: $0 == 0) }
            for r in rigs { r.toggle(); #expect(r.open, "\(side): didn't open") }
            var clock = (rigs.map(\.now).max() ?? 0) + 10
            let began = clock
            let before = rigs.map(\.fake.frame)
            for r in rigs {
                r.fake.behaviour.hangs = true
                r.fake.now = { clock }
                r.fake.wait = { clock += $0 }
                r.instance.clock = { clock }
                r.instance.pause = { clock += $0 }
            }
            SidebarController.shared.giveSpaceBack(of: rigs.map(\.instance), clock: { clock }, pause: { clock += $0 })
            for r in rigs { r.instance.close(closed: false) }
            #expect(clock - began <= GuardTiming.quit + 0.02, "\(side), 12 windows: turning off waited \(Int((clock - began) * 1000)) ms")
            for (r, f) in zip(rigs, before) { #expect(GuardFrames.same(r.fake.frame, f), "\(side): a hung window moved to \(r.fake.frame)") }
        }
    }

    /// Nick on 0.3.27 (and live on 3d5c1e4: Chrome for Testing filling the
    /// screen, the sidebar on the left at 280): around the moment the
    /// browser stops at the end of a hide, the whole sidebar flashed over it
    /// for an instant. Once a hide's slide has hidden the panel, nothing of
    /// it shows until the next show; nor after a refusal's note.
    @Test func aHideNeverShowsThePanelAgain() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let full = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        for side in SidebarSide.allCases {
            for b in [BrowserBehaviour(), BrowserBehaviour(animation: 0.25), BrowserBehaviour(timing: .late, lateBy: 0.3)] {
                let rig = SidebarRig(displays: [screen], frame: full, side: side, width: 280, behaviour: b)
                rig.toggle()
                #expect(rig.open, "\(side) \(b): didn't open")
                rig.toggle()
                var check = RuleCheck(rig, displays: [screen])
                check.nothingShowsOnceClosed("\(side) \(b): hide")
                #expect(!rig.open && GuardFrames.same(rig.fake.frame, full), "\(side) \(b): open \(rig.open), at \(rig.fake.frame)")
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
            }
            // Refused (Brave at 615 pt beside the screen's right edge): nothing shows after the note.
            let rig = SidebarRig(displays: [screen], frame: CGRect(x: 1256, y: 0, width: 800, height: 1259), side: side, width: 280,
                                 behaviour: BrowserBehaviour(minWidth: 615))
            rig.toggle()
            var check = RuleCheck(rig, displays: [screen])
            check.nothingShowsOnceClosed("\(side): refused")
            #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
        }
    }

    /// The browser's enhanced UI (on, as Nick's Chrome and Brave have it)
    /// is set back to what it was on every path a motion can end by: a show
    /// and a hide that land, a refusal (no room; no size taken at all, at
    /// the cap), a press that takes over mid-motion, the person's change
    /// mid-motion, quitting and turning the sidebar off mid-motion, a hung
    /// browser at quit (recorded for the next launch, within quitting's
    /// bound), and the window closing mid-motion.
    @Test func theFlagIsSetBackOnEveryPath() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let full = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        let narrow = CGRect(x: 1256, y: 0, width: 800, height: 1259)
        for side in SidebarSide.allCases {
            let on = BrowserBehaviour(enhancedUI: true)
            var paths: [(String, CGRect, BrowserBehaviour, [(at: Double, what: SidebarRig.During)])] = [
                ("show and hide", full, on, []),
                ("refused, no room", narrow, BrowserBehaviour(minWidth: 615, enhancedUI: true), []),
                ("refused at the cap", full, BrowserBehaviour(positionOnly: true, enhancedUI: true), []),
                ("pressed again mid-show", full, on, [(0.1, .press)]),
                ("pressed twice mid-show", full, on, [(0.05, .press), (0.12, .press)]),
                ("moved by the person mid-show", full, on, [(0.1, .person(left: -40, right: -40, dy: -20))]),
                ("quit mid-show", full, on, [(0.1, .quit)]),
                ("turned off mid-show", full, on, [(0.1, .turnOff)]),
            ]
            paths.append(("quit mid-show, the browser hung", full, on, [(0.1, .quitHung)]))
            for (what, frame, b, during) in paths {
                let rig = SidebarRig(displays: [screen], frame: frame, side: side, width: 280, behaviour: b)
                rig.toggle(during: during)
                var check = RuleCheck(rig, displays: [screen])
                check.flagRestored("\(side), \(what)")
                check.quitBound("\(side), \(what)")
                if rig.open, !rig.gone {
                    rig.toggle()
                    check.flagRestored("\(side), \(what), then hidden")
                }
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
            }
            // The window closes mid-show: its motion is over, and the flag set back.
            let rig = SidebarRig(displays: [screen], frame: full, side: side, width: 280, behaviour: on)
            rig.toggle(within: 0.1)
            #expect(!FakeApps.shared.flag(rig.pid), "\(side): the flag isn't off mid-show")
            rig.instance.close(closed: true)
            #expect(FakeApps.shared.flag(rig.pid) && !EnhancedUI.shared.isHeld(rig.pid), "\(side): closed mid-show, flag \(FakeApps.shared.flag(rig.pid))")
            #expect(EnhancedUI.shared.read().isEmpty, "\(side): still recorded \(EnhancedUI.shared.read())")
        }
    }

    /// Only the browser whose window is moved has its enhanced UI touched:
    /// another browser's, on as well, is never read or set. A flag already
    /// off is read, never set.
    @Test func onlyTheMovedBrowsersFlagIsTouched() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let a = SidebarRig(displays: [screen], frame: CGRect(x: 0, y: 0, width: 1028, height: 1259), side: .left, width: 280,
                           behaviour: BrowserBehaviour(enhancedUI: true), pid: 50_101)
        let b = SidebarRig(displays: [screen], frame: CGRect(x: 1028, y: 0, width: 1028, height: 1259), side: .left, width: 280,
                           behaviour: BrowserBehaviour(enhancedUI: true), pid: 50_102, freshApps: false)
        a.toggle()
        a.toggle()
        #expect(!FakeApps.shared.calls.contains { $0.pid == b.pid }, "the other browser's flag touched: \(FakeApps.shared.calls)")
        #expect(FakeApps.shared.flag(a.pid) && FakeApps.shared.flag(b.pid))
        #expect(FakeApps.shared.calls.filter { $0.pid == a.pid && $0.set != nil }.map(\.set) == [false, true, false, true],
                "\(FakeApps.shared.calls.map(\.set))")
        let off = SidebarRig(displays: [screen], frame: CGRect(x: 0, y: 0, width: 2056, height: 1259), side: .right, width: 280,
                             behaviour: BrowserBehaviour(), pid: 50_103)
        off.toggle()
        off.toggle()
        #expect(FakeApps.shared.calls.allSatisfy { $0.set == nil }, "a flag that was off was set: \(FakeApps.shared.calls.map(\.set))")
        #expect(FakeApps.shared.calls.count == 2, "one read per motion: \(FakeApps.shared.calls.count)")
    }

    /// An open without a slide (the window followed with its sidebar on, or
    /// a new width) over a browser that hasn't moved yet: the panel is
    /// masked to where the browser really is before it is placed or ordered
    /// in, so it is never drawn over the browser, not even for a moment
    /// (review of cfe553f, F1: the new width's placement, and the first
    /// order-in of a followed window whose browser reads back the size asked
    /// before taking it, showed it whole first).
    @Test func anOpenWithoutASlideIsNeverShownOverTheBrowser() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let half = CGRect(x: 0, y: 0, width: 1028, height: 1259)
        for side in SidebarSide.allCases {
            for b in [BrowserBehaviour(timing: .late, lateBy: 0.3), BrowserBehaviour(timing: .busy, lateBy: 0.3), BrowserBehaviour(revertReads: 3)] {
                let followed = SidebarRig(displays: [screen], frame: half, side: side, width: 280, behaviour: b, hidden: false)
                followed.follow()
                var check = RuleCheck(followed, displays: [screen])
                check.nothingShowsOnceClosed("\(side) \(b), followed")
                if b.sizesStick { #expect(followed.open, "\(side) \(b): followed, didn't open") }
                let rig = SidebarRig(displays: [screen], frame: half, side: side, width: 280, behaviour: BrowserBehaviour())
                rig.toggle()
                rig.fake.behaviour = b
                rig.carry(.width(360), during: [])
                check = RuleCheck(rig, displays: [screen])
                check.nothingShowsOnceClosed("\(side) \(b), a new width")
                if b.sizesStick { #expect(rig.open && abs(rig.sidebarWidth - 360) < 2, "\(side) \(b): new width, open \(rig.open), \(rig.sidebarWidth)") }
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
            }
        }
        // Seed 6221202 case 155: a right half, the sidebar on the right, a browser that reads back the size asked 4 times.
        let wide = Display(frame: CGRect(x: 0, y: 0, width: 2690, height: 1533), visibleFrame: CGRect(x: 0, y: 86, width: 2690, height: 1414), scale: 2)
        let rig = SidebarRig(displays: [wide], frame: CGRect(x: 1345, y: 86, width: 1345, height: 1414), side: .right, width: 285,
                             behaviour: BrowserBehaviour(revertReads: 4), hidden: false)
        rig.follow()
        var check = RuleCheck(rig, displays: [wide])
        check.nothingShowsOnceClosed("case 155, followed")
        #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
    }

    /// Quitting or turning the sidebar off mid-slide: the panel is ordered
    /// out before its mask is lifted and before the browser is given its
    /// space back, so nothing of it is drawn over the browser (review of
    /// cfe553f, F2: `spaceBack` lifted the mask on a panel still shown).
    @Test func lettingGoMidSlideShowsNothingOverTheBrowser() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let full = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        for side in SidebarSide.allCases {
            for what in [SidebarRig.During.quit, .turnOff] {
                for showing in [true, false] {
                    let rig = SidebarRig(displays: [screen], frame: full, side: side, width: 280, behaviour: BrowserBehaviour(animation: 0.25))
                    if !showing { rig.toggle() }
                    rig.toggle(during: [(0.1, what)])
                    var check = RuleCheck(rig, displays: [screen])
                    check.nothingShowsOnceClosed("\(side), \(what) mid-\(showing ? "show" : "hide")")
                    #expect(rig.gone && check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                }
            }
        }
    }

    /// Nick's report on 0.3.27, macOS 27.2.1, the sidebar on the left: on
    /// show, the browser's right edge animated in by the sidebar's width,
    /// then the sidebar slid in with the browser's left edge; on hide, the
    /// browser slid left with the sidebar, then its right edge grew back.
    /// His Chrome and Brave read AXEnhancedUserInterface on, and each set
    /// answers -25208 and takes. Now, either side: the flag is set off for
    /// the motion and back after, the browser's far edge never moves, the
    /// browser moves with the slide frame by frame, the sidebar shows just
    /// as far as the browser has made room, and the pair is the frame it was.
    /// One late set never ends the glide for good (MINI-16 on macOS 27,
    /// 1df43a3: one set of show 3 showed 70 ms late, the glide gave way, and
    /// every show and hide after was the old two steps, the far edge moving
    /// 280 pt). Late on screen, or a call that held betterlink up: within a
    /// glide one such frame is waited for and the glide goes on; a probe
    /// that shows late falls back for that motion only, and the next glides.
    @Test func oneLateSetNeverEndsTheGlide() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        let full = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        enum Late: CaseIterable { case onScreen, holdsCaller }
        for side in SidebarSide.allCases {
            for b in [BrowserBehaviour(enhancedUI: true), BrowserBehaviour()] {
                for late in Late.allCases {
                    // Which motion has the late set, and which of its calls: the first motion's first is its probe.
                    for (motion, call) in [(0, 1), (2, 1), (2, 3), (3, 4)] {
                        let rig = SidebarRig(displays: [screen], frame: full, side: side, width: 280, behaviour: b)
                        var check = RuleCheck(rig, displays: [screen])
                        for k in 0..<6 {
                            if k == motion {
                                switch late {
                                case .onScreen: rig.fake.showsLate(call: call, by: 0.07)
                                case .holdsCaller: rig.fake.holdsCaller(call: call, by: 0.07)
                                }
                            }
                            rig.toggle()
                            // A probe shown late falls back for its motion; every other motion glides.
                            if k == motion, motion == 0 { continue }
                            check.oneSmoothMotion(pair: full, "\(side) \(b), \(late) late set \(call) of motion \(motion + 1): motion \(k + 1)")
                        }
                        #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                    }
                }
            }
        }
    }

    /// 40 shows and hides of a left sidebar, on a browser whose sets land at
    /// once (its flag off, or on and set off), every one a glide: a left
    /// glide sends a size and a position each frame, and the position now
    /// and then waits for the browser, busy with the size (MINI-16 on macOS
    /// 27, 1df43a3: four left glides, then `slow` and the two steps for
    /// good; right glides, one call a frame, 40 of 40). A frame shows when
    /// its calls have returned: it isn't late.
    @Test func fortyLeftGlidesWithPairedSets() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        let full = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        for b in [BrowserBehaviour(), BrowserBehaviour(enhancedUI: true)] {
            let rig = SidebarRig(displays: [screen], frame: full, side: .left, width: 280, behaviour: b)
            rig.fake.pairedPositionHolds = (every: 12, by: 0.055)
            var check = RuleCheck(rig, displays: [screen])
            for k in 0..<40 {
                rig.toggle()
                check.oneSmoothMotion(pair: full, "\(b): \(k % 2 == 0 ? "show" : "hide") \(k / 2 + 1)")
            }
            check.flagRestored("\(b)")
            #expect(check.problems.isEmpty, "\(check.problems.prefix(6).joined(separator: "\n"))")
        }
    }

    /// VoiceOver on: a show and a hide leave the browser's flag alone (no
    /// read, no set) and move it as before there was a hold, by
    /// `WindowSteps`, its sets animated by the flag; the four rules hold.
    @Test func voiceOverOnLeavesTheFlagAlone() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        let full = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        defer { EnhancedUI.shared.assistive = EnhancedUI.systemAssistive }
        for side in SidebarSide.allCases {
            let rig = SidebarRig(displays: [screen], frame: full, side: side, width: 280, behaviour: BrowserBehaviour(enhancedUI: true))
            EnhancedUI.shared.assistive = { "VoiceOver" }
            var lines: [String] = []
            DragTrace.echo = { lines.append($0) }
            defer { DragTrace.echo = nil }
            rig.toggle()
            var check = RuleCheck(rig, displays: [screen])
            check.shown(from: full, mustOpen: true, "\(side): show")
            check.timely("\(side): show")
            let browser = rig.fake.frame
            rig.toggle()
            check.hidden(from: browser, sidebar: 280, wasOpen: true, "\(side): hide")
            check.timely("\(side): hide")
            #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
            #expect(FakeApps.shared.calls.isEmpty, "\(side): the flag touched: \(FakeApps.shared.calls.map(\.set))")
            #expect(FakeApps.shared.flag(rig.pid), "\(side): the flag is off")
            #expect(!lines.contains { $0.hasPrefix("glide:") }, "\(side): glided with VoiceOver on")
            #expect(lines.filter { $0.contains("left alone, VoiceOver on") }.count == 2, "\(side): \(lines.filter { $0.contains("enhanced UI") })")
        }
    }

    @Test func nicksShowAndHideOnAnEnhancedUIBrowser() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1329),
                             visibleFrame: CGRect(x: 0, y: 4, width: 2056, height: 1329 - 39 - 4), scale: 2)
        let full = CGRect(x: 0, y: 0, width: 2056, height: 1290)
        for side in SidebarSide.allCases {
            for b in [BrowserBehaviour(enhancedUI: true), BrowserBehaviour(minWidth: 615, enhancedUI: true), BrowserBehaviour()] {
                let rig = SidebarRig(displays: [screen], frame: full, side: side, width: 280, behaviour: b)
                rig.toggle()
                let step = "\(side) \(b)"
                var check = RuleCheck(rig, displays: [screen])
                check.shown(from: full, mustOpen: true, "\(step): show")
                check.oneSmoothMotion(pair: full, "\(step): show")
                check.flagRestored("\(step): show")
                check.timely("\(step): show")
                let browser = rig.fake.frame
                rig.toggle()
                check.hidden(from: browser, sidebar: 280, wasOpen: true, "\(step): hide")
                check.oneSmoothMotion(pair: full, "\(step): hide")
                check.nothingShowsOnceClosed("\(step): hide")
                check.flagRestored("\(step): hide")
                check.timely("\(step): hide")
                // Shown again: the second show glides as the first did.
                rig.toggle()
                check.oneSmoothMotion(pair: full, "\(step): shown again")
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                #expect(FakeApps.shared.flag(rig.pid) == b.enhancedUI, "\(step): the flag is \(FakeApps.shared.flag(rig.pid))")
            }
        }
    }

    /// Bug 3, live on 3d5c1e4 (Chrome for Testing, the sidebar on the left
    /// at 280): with the sidebar open, the window put on the whole visible
    /// frame (Window › Fill, a tiling app, a zoom) left the sidebar off the
    /// screen at -280, from a pair at 400...1656 and from one filling the
    /// screen. The browser now yields the sidebar's width on its side, the
    /// sidebar slides back on, and the pair is the frame the person chose.
    /// The person drags the open browser's edge over where its sidebar was,
    /// the sidebar still on the screen: their frame stands, the sidebar where
    /// it was (rule 3; review F1 of 1df43a3: a left edge dragged from 400 to
    /// 300 beside a 280 pt left sidebar was put back at 580...1600).
    @Test func aResizeOverTheSidebarStands() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        for side in SidebarSide.allCases {
            let start = CGRect(x: 120, y: 0, width: 1480, height: 1259)
            let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: BrowserBehaviour())
            rig.toggle()
            #expect(rig.open, "\(side): didn't open")
            let b = rig.fake.frame
            // 100 pt over where the sidebar is.
            let f = side == .left ? CGRect(x: b.minX - 100, y: b.minY, width: b.width + 100, height: b.height)
                                  : CGRect(x: b.minX, y: b.minY, width: b.width + 100, height: b.height)
            rig.personSets(f)
            var check = RuleCheck(rig, displays: [screen])
            check.personDid(f, "\(side): the edge dragged 100 over the sidebar")
            #expect(rig.open, "\(side): closed after the resize")
            #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
        }
    }

    /// The review of 9354d68: with the pair against the screen's edge, a drag
    /// of the browser's edge on the sidebar's side takes the sidebar partly
    /// off the screen, and the pair was fitted again, 180 pt narrower than
    /// the person left the browser. A drag of one horizontal edge, or of a
    /// corner, is the person's and stands, wherever it leaves the sidebar
    /// (rule 3). Only a placement (both horizontal edges moved, or the whole
    /// visible frame) fits the pair again.
    private func personDrags(side: SidebarSide, _ what: String, from want: CGRect, to put: (CGRect) -> CGRect) {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let rig = SidebarRig(displays: [screen], frame: screen.visibleFrame, side: side, width: 280, behaviour: BrowserBehaviour())
        rig.toggle()
        let b = rig.fake.frame
        #expect(rig.open && GuardFrames.same(b, want), "\(side): opened \(rig.open) at \(b), wanted \(want)")
        let f = put(b)
        rig.personSets(f)
        var check = RuleCheck(rig, displays: [screen])
        check.personDid(f, "\(side): \(what)")
        #expect(rig.open && abs(rig.sidebarWidth - 280) < 2, "\(side): \(what): open \(rig.open), sidebar \(rig.sidebarWidth)")
        #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
    }

    @Test func aRightEdgeDraggedPastTheScreenStands() {
        personDrags(side: .right, "the right edge dragged 100 to the right", from: CGRect(x: 0, y: 0, width: 1776, height: 1259)) {
            CGRect(x: $0.minX, y: $0.minY, width: $0.width + 100, height: $0.height)
        }
    }

    @Test func aLeftEdgeDraggedPastTheScreenStands() {
        personDrags(side: .left, "the left edge dragged 100 to the left", from: CGRect(x: 280, y: 0, width: 1776, height: 1259)) {
            CGRect(x: $0.minX - 100, y: $0.minY, width: $0.width + 100, height: $0.height)
        }
    }

    @Test func aCornerDragStands() {
        personDrags(side: .right, "the bottom right corner dragged 100 right and 200 up", from: CGRect(x: 0, y: 0, width: 1776, height: 1259)) {
            CGRect(x: $0.minX, y: $0.minY + 200, width: $0.width + 100, height: $0.height - 200)
        }
        personDrags(side: .left, "the top left corner dragged 100 left and 200 down", from: CGRect(x: 280, y: 0, width: 1776, height: 1259)) {
            CGRect(x: $0.minX - 100, y: $0.minY, width: $0.width + 100, height: $0.height - 200)
        }
    }

    /// macOS tiling (Window › Move & Resize, or dragging to the screen's edge)
    /// to the left half or the top left quarter with the sidebar on the left:
    /// both horizontal edges move and the sidebar would be off the screen, so
    /// the pair fits again in the tile.
    @Test func tilingToTheLeftHalfFitsThePairAgain() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        for tile in [CGRect(x: 0, y: 0, width: 1028, height: 1259), CGRect(x: 0, y: 630, width: 1028, height: 629)] {
            for start in [screen.visibleFrame, CGRect(x: 400, y: 0, width: 1256, height: 1259)] {
                let rig = SidebarRig(displays: [screen], frame: start, side: .left, width: 280, behaviour: BrowserBehaviour())
                rig.toggle()
                #expect(rig.open, "from \(start): didn't open")
                let before = rig.fake.frame
                rig.personSets(tile)
                let step = "from \(start), tiled to \(tile)"
                var check = RuleCheck(rig, displays: [screen])
                check.shown(from: tile, mustOpen: true, step)
                check.sidebarStaysOnScreen(before: before, width: 280, put: tile, step)
                #expect(rig.open && abs(rig.sidebarWidth - 280) < 2, "\(step): open \(rig.open), sidebar \(rig.sidebarWidth)")
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
            }
        }
    }

    @Test func fillWhileOpenFitsThePairAgain() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let fill = screen.visibleFrame
        for side in SidebarSide.allCases {
            for start in [CGRect(x: 400, y: 0, width: 1256, height: 1259), fill] {
                for b in [BrowserBehaviour(), BrowserBehaviour(enhancedUI: true), BrowserBehaviour(animation: 0.25)] {
                    let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: b)
                    rig.toggle()
                    #expect(rig.open, "\(side) \(start): didn't open")
                    let before = rig.fake.frame
                    rig.personSets(fill)
                    let step = "\(side) \(b), from \(start), filled"
                    var check = RuleCheck(rig, displays: [screen])
                    check.shown(from: fill, mustOpen: true, step)
                    check.sidebarStaysOnScreen(before: before, width: 280, put: fill, step)
                    check.flagRestored(step)
                    #expect(rig.open && abs(rig.sidebarWidth - 280) < 2, "\(step): open \(rig.open), sidebar \(rig.sidebarWidth)")
                    #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
                    // And hidden: the browser takes the whole visible frame.
                    let b2 = rig.fake.frame
                    rig.toggle()
                    check.hidden(from: b2, sidebar: 280, wasOpen: true, "\(step), then hidden")
                    #expect(GuardFrames.same(rig.fake.frame, fill), "\(step), hidden at \(rig.fake.frame)")
                }
            }
        }
    }

    /// Native full screen (the green button, a Space of its own) was right
    /// already on 3d5c1e4 (live: the panel left the screen, and on exit the
    /// pair came back exactly). Entering hides the sidebar, leaving puts
    /// back the pair as it was; a hide pressed meanwhile sends the window
    /// nothing, and gives it the pair's frame once it has left.
    @Test func nativeFullScreenHidesTheSidebarAndLeavingRestoresThePair() {
        let screen = Display(frame: CGRect(x: 0, y: 0, width: 2056, height: 1290),
                             visibleFrame: CGRect(x: 0, y: 0, width: 2056, height: 1259), scale: 2)
        let start = CGRect(x: 400, y: 0, width: 1256, height: 1259)
        for side in SidebarSide.allCases {
            for pressMeanwhile in [false, true] {
                let rig = SidebarRig(displays: [screen], frame: start, side: side, width: 280, behaviour: BrowserBehaviour(enhancedUI: true))
                rig.toggle()
                let open = rig.fake.frame
                rig.fake.enterFullScreen(screen.frame)
                rig.personSets(screen.frame)
                let step = "\(side)\(pressMeanwhile ? ", hidden in full screen" : "")"
                #expect(!rig.instance.isShown, "\(step): the sidebar shown in full screen")
                #expect(GuardFrames.same(rig.fake.frame, screen.frame), "\(step): full screen at \(rig.fake.frame)")
                let calls = rig.fake.setCalls
                if pressMeanwhile { rig.toggle() }
                #expect(rig.fake.setCalls == calls, "\(step): the full screen window was sent \(rig.fake.setCalls - calls) call(s)")
                rig.fake.exitFullScreen()
                rig.personSets(open)
                var check = RuleCheck(rig, displays: [screen])
                if pressMeanwhile {
                    check.hidden(from: open, sidebar: 280, wasOpen: true, step)
                    #expect(GuardFrames.same(rig.fake.frame, start), "\(step): at \(rig.fake.frame) after leaving full screen, wanted \(start)")
                } else {
                    check.shown(from: start, mustOpen: true, step)
                    #expect(rig.instance.isShown && GuardFrames.same(rig.fake.frame, open), "\(step): shown \(rig.instance.isShown), at \(rig.fake.frame)")
                }
                check.flagRestored(step)
                #expect(check.problems.isEmpty, "\(check.problems.joined(separator: "\n"))")
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

/// betterlink's bounds on its waits, as the guard holds it to them: a whole
/// show or hide (every call it makes, the browser's answer included) is
/// capped at `cap`; quitting holds the app up no longer than `quit`,
/// however many windows there are and whatever their browsers do.
enum GuardTiming {
    static let cap = 3.0
    static let quit = 4 * WindowSteps.timeout
}

/// Frames within 2 pt count as the same: the browser rounds.
enum GuardFrames {
    static func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
}
