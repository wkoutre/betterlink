import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Moving a browser window with the sidebar's slide, one frame per tick, its
/// far edge (away from the sidebar) kept where it is: one smooth motion
/// instead of a size and then a position (Nick on 0.3.27: the browser's far
/// edge animated in by the sidebar's width, then the whole browser slid).
///
/// Only for sets that land at once: with the browser's enhanced user
/// interface off (`EnhancedUI`), a size and a position sent within one
/// display refresh land as one frame (measured on macOS 26.5.2 and Nick's
/// 27.2.1). Each tick:
///
/// - The frame for the slide's progress, `closed` at 0 and `open` at 1, in
///   whole points, its far edge where `closed` and `open` have it.
/// - Narrowing: the size, the width it took read back at once (a browser at
///   its minimum takes less), then the position that puts its far edge back
///   at that width. Widening: the same, size first, where the window can
///   grow from where it is without passing its screens' right edge (`right`);
///   else the position first (a window can't grow past its screen's edge),
///   then the size, then the position once more if it took less. Calls that
///   change nothing are not sent.
/// - The next frame is sent only once the window server shows this one.
///
/// It gives way to `WindowSteps` (`done`, not `interrupted`), which ends the
/// motion with its own checks from where the window is (`handover`), when:
/// the slide is over and its last frame landed; a frame took longer than
/// `instant` to show (`slow`: these sets are animated or late, and the
/// glide's single frame is all that was spent on finding out); the window
/// moved and then stood still short of the frame for `WindowSteps.still`; a
/// size changed nothing (the browser is at its minimum, or late). A frame
/// that changes nothing within `WindowSteps.timeout` is sent once more (a
/// call can be dropped). A change no call of the frame can make (the top
/// edge or height, or a left edge that is neither where it was nor where it
/// was sent) is someone else's: `interrupted`, and nothing more is sent.
///
/// Pure: the caller reads the window on screen, sends what `step` and
/// `next` return in one go, and passes back the width read after each size.
public struct WindowGlide: Sendable {
    public typealias Call = WindowSteps.Call

    public private(set) var closed: CGRect
    public private(set) var open: CGRect
    public let side: SidebarSide
    /// How far right the window can grow from where it is: the right edge of
    /// the displays side by side at its height. Nil: not past where it is.
    public let right: CGFloat?

    public private(set) var done = false
    public private(set) var interrupted = false
    /// A frame took longer than `instant` to show.
    public private(set) var slow = false
    public private(set) var capped = false

    /// The window when the glide began; whether it has changed since; when
    /// the last call was sent; and when the window last changed.
    public private(set) var start: CGRect?
    public private(set) var moved = false
    public private(set) var sentAt = 0.0
    public private(set) var changedAt = 0.0

    /// Longer than this to show a frame: the browser's sets don't land at once.
    public static let instant = 0.05
    /// The least a probe asks of the window's width.
    public static let probeStep: CGFloat = 4

    private enum Next { case size, place, positionFirst, fix }
    private var plan: [Next] = []
    /// The frame these calls are for, where the window was when they began,
    /// and what they give as far as is known (the width read back).
    private var asked: CGRect?
    private var before: CGRect?
    private var expect: CGRect?
    private var last: CGRect?
    private var final = false
    /// The frame in flight was asked before a `retarget`: never sent again.
    private var foreign = false
    private var resent = false
    /// The width this frame's size gave, read back.
    private var took: CGFloat?
    /// The last frame sent has landed: nothing of the glide's is on its way.
    private var landedLast = true
    /// The last call sent, when, and the window then.
    private var lastCall: (call: Call, at: Double, from: CGRect)?
    /// The browser resized the window between two frames, keeping its top
    /// left (widened itself back to its minimum): nothing is on its way.
    private var resizedItself = false
    /// A size changed nothing: the browser is at its minimum (or late).
    private var stoppedAtSize = false
    /// The read after this frame's size said it changed nothing: what the window server shows decides.
    private var unread = false
    /// The frame out widens the window.
    private var widening = false
    /// The slide's progress at the last tick, and which way it goes.
    private var lastProgress: Double?
    private var goingOpen: Bool?
    /// The probe didn't show within `instant`.
    private var probeOut = false

    /// `proven`: this window's sets were seen to land at once before. Until
    /// they are, the first frame is a probe: its size alone, and only once
    /// it shows within `instant` do frames go out as a size and a position
    /// together. A probe that doesn't (macOS animating anyway, a browser
    /// late or busy) hands over at once to steps that start afresh and send
    /// their size straight away, as before there was a glide: it is never
    /// followed by a position that an animation would cut it short with, and
    /// a size cutting a size short, or landing after it, keeps the top left.
    public init(closed: CGRect, open: CGRect, side: SidebarSide, right: CGFloat?, proven: Bool = true) {
        self.closed = closed
        self.open = open
        self.side = side
        self.right = right
        self.proven = proven
    }

    /// The window's sets were seen to land at once (by now, or before).
    public private(set) var proven: Bool
    /// The probe is out.
    private var probing = false

    /// The slide turned back, or its frames changed: the same glide goes on
    /// toward them. A frame in flight is waited for, never sent again.
    public mutating func retarget(closed: CGRect, open: CGRect) {
        self.closed = closed
        self.open = open
        if expect != nil { foreign = true }
        final = false
    }

    private static func near(_ a: CGFloat, _ b: CGFloat, _ by: CGFloat = 1) -> Bool { abs(a - b) < by }

    private static func landed(_ seen: CGRect, _ e: CGRect) -> Bool {
        near(seen.minX, e.minX) && near(seen.width, e.width) && near(seen.maxY, e.maxY) && near(seen.height, e.height)
    }

    /// The frame at progress `q`, in whole points.
    public func frame(at q: Double) -> CGRect {
        if q <= 0 { return closed }
        if q >= 1 { return open }
        let f = CGFloat(q)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * f).rounded() }
        let x0 = mix(closed.minX, open.minX), x1 = mix(closed.maxX, open.maxX)
        let y0 = mix(closed.minY, open.minY), y1 = mix(closed.maxY, open.maxY)
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    /// Whether `seen` is one the calls of the frame in flight can give, on
    /// the way too (an animated call passes every place between): its top
    /// edge, height and left edge between where it was and where it was sent.
    private func ours(_ seen: CGRect) -> Bool {
        guard let b = before, let a = asked else { return true }
        func within(_ v: CGFloat, _ xs: [CGFloat]) -> Bool { v >= (xs.min() ?? v) - 1.5 && v <= (xs.max() ?? v) + 1.5 }
        var xs = [b.minX, a.minX]
        if let e = expect { xs.append(e.minX) }
        if let w = took { xs.append(side == .left ? a.maxX - w : a.minX) }
        return within(seen.maxY, [b.maxY, a.maxY]) && within(seen.height, [b.height, a.height]) && within(seen.minX, xs)
    }

    /// The first call of this tick, given the window on screen (`seen`), the
    /// slide's progress `q` (1 open) and whether the slide is over (`end`).
    public mutating func step(seen: CGRect, now: Double, progress q: Double, end: Bool, deadline: Double?) -> Call? {
        if done { return nil }
        if start == nil { start = seen; before = seen; last = seen; changedAt = now }
        if seen != last {
            last = seen
            changedAt = now
            if let s = start, seen != s { moved = true }
        }
        if let deadline, now >= deadline { capped = true; done = true; return nil }
        if let e = expect {
            guard ours(seen) else { interrupted = true; done = true; return nil }
            if unread {
                // Shown after all: the read was behind. The frame's position, at the width shown, goes now.
                if Self.landed(seen, e) {
                    unread = false
                    plan = [.place]
                    return next(width: seen.width)
                }
                // Not shown at once either: the browser stopped there (its minimum). The steps go on from here,
                // as after their own size.
                if now - sentAt > Self.instant {
                    stoppedAtSize = true
                    done = true
                }
                return nil
            }
            if !probing, Self.landed(seen, e) {
                expect = nil; asked = nil; took = nil; unread = false
                before = seen
                foreign = false
                landedLast = true
                // Shown, but later than sets that land at once: nothing is in flight now, the rest is the steps'.
                if now - sentAt > Self.instant { slow = true; done = true; return nil }
                if final { done = true; return nil }
            } else if probing {
                if Self.near(seen.minX, e.minX, 0.5), Self.near(seen.width, e.width, 0.5), Self.near(seen.maxY, e.maxY, 0.5) {
                    if now - sentAt > Self.instant { slow = true; landedLast = true; done = true; return nil }
                    probing = false
                    proven = true
                    expect = nil; asked = nil; took = nil
                    before = seen
                    landedLast = true
                    if final { done = true; return nil }
                } else {
                    if now - sentAt > Self.instant { slow = true; probeOut = true; done = true }
                    return nil
                }
            } else {
                let changed = changedAt > sentAt
                if changed, now - changedAt >= WindowSteps.still {
                    if now - sentAt > Self.instant { slow = true }
                    done = true
                    return nil
                }
                if !changed, now - sentAt >= WindowSteps.timeout, !foreign, !resent, let b = before, let a = asked {
                    // Nothing came of it: sent once more (a call can be dropped).
                    resent = true
                    return begin(a, from: b, now: now)
                }
                return nil
            }
        }
        guard let b = before else { return nil }
        if !Self.landed(seen, b) {
            // Resized between two frames, its top left kept: the browser's own (back to its minimum). The rest is the steps'.
            if Self.near(seen.minX, b.minX), Self.near(seen.maxY, b.maxY), Self.near(seen.height, b.height) {
                resizedItself = true
                done = true
                return nil
            }
            // Moved between two frames, by no call of this glide's: someone else's.
            interrupted = true
            done = true
            return nil
        }
        let f = end ? (q >= 0.5 ? open : closed) : frame(at: q)
        // Never back along the slide: a frame behind where the window is (the probe went ahead of the slide) waits.
        if let last = lastProgress, q != last { goingOpen = q > last }
        lastProgress = q
        if !end, let o = goingOpen {
            let going = o ? open : closed
            if abs(f.width - going.width) > abs(b.width - going.width) + 0.5 { return nil }
        }
        if Self.landed(f, b) {
            // Already where the slide ends: the glide ended where the motion is going.
            if end { final = true; done = true }
            return nil
        }
        final = end
        resent = false
        return begin(f, from: b, now: now)
    }

    private mutating func begin(_ f: CGRect, from b: CGRect, now: Double) -> Call? {
        widening = f.width > b.width + 0.5
        asked = f
        took = nil
        sentAt = now
        expect = f
        landedLast = false
        if !proven, !(Self.near(f.width, b.width) && Self.near(f.height, b.height)) {
            // The probe: the size alone, at least `probeStep` from where the window is (an animation's first
            // step is under a point, and must not pass for having landed), never past where the slide ends.
            let toward: CGFloat = f.width < b.width ? -1 : 1
            let w = b.width + toward * min(max(abs(f.width - b.width), Self.probeStep), abs((f.width < b.width ? min(open.width, closed.width) : max(open.width, closed.width)) - b.width))
            probing = true
            let p = CGRect(x: b.minX, y: b.maxY - f.height, width: w, height: f.height)
            asked = p
            expect = p
            plan = []
            lastCall = (.size(p), now, b)
            return .size(p)
        }
        if Self.near(f.width, b.width) && Self.near(f.height, b.height) {
            plan = [.place]
        } else if f.width < b.width || right.map({ b.minX + f.width <= $0 + 0.5 }) ?? false {
            plan = [.size, .place]
        } else {
            plan = [.positionFirst, .size, .fix]
        }
        return next(width: nil)
    }

    /// The next call of this tick, after the last was sent; `width`: the
    /// window's width read back after a size call (nil: none read).
    /// `unanswered`: the read after a size got no answer (the browser
    /// busy): its sets don't land at once. Narrowing, the glide gives way at
    /// once, as after a probe that didn't land (`slow`), its position not
    /// sent (it may have stopped at its minimum), and the steps send their
    /// size after the glide's. Widening, the size is taken as asked and the
    /// frame waited for whole: given way with its position and size both on
    /// their way, a burst of the two would pass for someone else's change.
    public mutating func next(width: CGFloat?, unanswered: Bool = false) -> Call? {
        if unanswered, !widening, asked != nil {
            plan = []
            slow = true
            probeOut = true
            done = true
            return nil
        }
        let c = plan(width: width)
        if let c, let b = before { lastCall = (c, sentAt, b) }
        return c
    }

    private mutating func plan(width: CGFloat?) -> Call? {
        guard let f = asked, let b = before else { return nil }
        if let width { took = width }
        while let n = plan.first {
            plan.removeFirst()
            switch n {
            case .size:
                if Self.near(f.width, b.width) && Self.near(f.height, b.height) { continue }
                return .size(f)
            case .positionFirst:
                // Where it grows from, at the width it has.
                let at = CGRect(x: f.minX, y: f.maxY - b.height, width: b.width, height: b.height)
                if Self.near(at.minX, b.minX) && Self.near(at.maxY, b.maxY) { continue }
                return .position(at)
            case .place, .fix:
                // A size the read says changed nothing: the browser is at its minimum, or late, or the read is
                // behind the window. Nothing more of this frame: the window server decides (`step`).
                if let w = took, !Self.near(f.width, b.width), Self.near(w, b.width, 0.5) {
                    expect = CGRect(x: n == .fix ? f.minX : b.minX, y: f.maxY - f.height, width: f.width, height: f.height)
                    plan = []
                    unread = true
                    return nil
                }
                let w = took ?? f.width
                let x = side == .left ? f.maxX - w : f.minX
                let at = CGRect(x: x, y: f.maxY - f.height, width: w, height: f.height)
                expect = at
                // After a size, the window's top left is where it was; after a position first, where it was sent.
                let from = n == .fix ? f.minX : b.minX
                if Self.near(x, from, 0.5) && Self.near(f.maxY, b.maxY, 0.5) { continue }
                return .position(at)
            }
        }
        return nil
    }

    /// How the steps that end the motion take over from the glide.
    public enum Handover: Sendable {
        /// Nothing of the glide's is on its way, and the window didn't end
        /// where the motion is going: they start afresh from where it is.
        case none
        /// The glide ended where the motion is going, or the browser resized
        /// the window itself: they go on as after their own size
        /// (`WindowSteps.Resume`), so a browser that widens itself back to its
        /// minimum, or stopped short, is checked as after a size.
        case holds(WindowSteps.Resume)
        /// A call of the glide's may still be on its way (animated, or late):
        /// they wait for it as a call taken over (`WindowSteps.after`).
        case waits(WindowSteps)
    }

    /// For the steps that go on from here, given the window now.
    /// `takenOver`: a press (or quitting) takes over mid-glide: a call of
    /// the glide's still on its way is the press before's, waited for and
    /// never sent again.
    public func handover(seen: CGRect, takenOver: Bool = false) -> Handover {
        guard let start else { return .none }
        // The probe didn't show at once (animated, late, busy or dropped). Narrowing: the steps start afresh and
        // send their own size at once, as they always did (a size that cuts a size short, or lands after it,
        // keeps the top left). Widening: their first call would be a position, which the probe landing late
        // would pass for someone else's change: they take the probe as their own call (sent again if dropped),
        // and go on from where it leaves the window.
        if probeOut {
            guard let c = lastCall, case .size(let f) = c.call, f.width > c.from.width + 0.5 else { return .none }
            return .waits(WindowSteps.inFlight(c.call, at: c.at, from: c.from, seen: seen, changed: changedAt, moved: changedAt > c.at, own: true))
        }
        // Taken over mid-probe: the press before's call, waited for and never sent again.
        if probing, let c = lastCall {
            return .waits(WindowSteps.inFlight(c.call, at: c.at, from: c.from, seen: seen, changed: changedAt, moved: changedAt > c.at))
        }
        guard moved else { return .none }
        let resume = WindowSteps.Resume(from: start, seen: seen, at: sentAt, changed: changedAt)
        if resizedItself { return .holds(resume) }
        if landedLast { return final || (stoppedAtSize && !widening) ? .holds(resume) : .none }
        // A size the browser didn't show at once. Narrowing: checked as after the steps' own size (its minimum, a
        // stop short). Widening: the steps start afresh, the position first, as they always did; sent again from
        // where the window is, the size would grow it the other way, past its screen's edge.
        if stoppedAtSize { return widening ? .none : .holds(resume) }
        guard let c = lastCall else { return .none }
        return .waits(WindowSteps.inFlight(c.call, at: c.at, from: c.from, seen: seen, changed: changedAt, moved: changedAt > c.at))
    }
}
