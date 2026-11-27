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
///   at that width. On the left, once a frame of this glide (or its probe)
///   landed at once as asked, and no size has been taken otherwise or gone
///   unanswered (`pairs`), the size and the position for the width asked go
///   back to back, nothing read between, and the width is read after both:
///   a read between them let the window server show the new width a refresh
///   before the new position, the far edge in by up to 120 pt for a frame
///   (live on macOS 26 and 27, after PR 105). A width read after them that
///   isn't the one asked puts the far edge back at once, in the same tick:
///   at the width taken (its minimum), or, a size that changed nothing (at
///   its minimum already, or dropped), the window back where it was and the
///   frame asked again with the read between; and the rest of the glide
///   reads between. Widening: the same, size first, where the window can
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
    /// Frames in a row seen still not shown `instant` after their calls
    /// returned, though each then showed whole: this many, and the sets are
    /// late (`slow`). One alone is a hiccup (MINI-16 on macOS 27, 1df43a3:
    /// one set showed 70 ms late, and the glide gave way for good), waited
    /// for, and the glide goes on.
    public static let lateFrames = 3
    /// The least a probe asks of the window's width.
    public static let probeStep: CGFloat = 4

    private enum Next { case size, place, placeAsked, check, positionFirst, fix }
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
    /// The frame in flight was seen not yet shown (a look at it after its
    /// calls returned); and how many frames in a row, so seen, showed only
    /// past `instant` after their calls returned (`lateFrames`).
    private var pendingSeen = false
    public private(set) var late = 0
    /// No call sent yet: the first goes out with the press (`step`).
    private var sentAny = false
    /// A frame of this glide (or its probe) landed at once as asked, its
    /// width read back as asked, and no size of it has been taken otherwise
    /// or gone unanswered: a left narrowing frame goes out as a size and its
    /// position back to back (`begin`). The first frame of every glide reads between
    /// (a browser at its minimum, late, busy or dropping sizes shows it
    /// there, where a position already sent would push the window past its
    /// far edge); once a size isn't taken as asked, or isn't answered, the
    /// rest of the glide reads between too (`noPairs`).
    private var pairs = false
    private var noPairs = false
    private mutating func stopPairs() { pairs = false; noPairs = true }

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

    /// Whether the caller reads the window's width back now, after the call
    /// it just sent: after a size, unless its position goes with it at once
    /// (a pair: nothing is read between the two); and after a pair's position.
    public var readsBack: Bool {
        guard let c = lastCall?.call else { return false }
        if case .size = c { return plan.first != .placeAsked }
        return plan.first == .check
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

    /// The tick's calls have returned, at `t`: whether a frame shows within
    /// `instant` is counted from here, not from before them, so a call the
    /// browser took long to answer (it landed meanwhile) isn't taken for a
    /// late one.
    public mutating func sent(at t: Double) {
        if expect != nil { sentAt = max(sentAt, t) }
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
                // Landed as asked, at once, the width read back as asked: the next left narrowing frame may pair.
                if !noPairs, !pendingSeen, let w = took, let a = asked, Self.near(w, a.width, 0.5), Self.near(seen.width, a.width, 0.5) { pairs = true }
                expect = nil; asked = nil; took = nil; unread = false
                before = seen
                foreign = false
                landedLast = true
                // Seen not shown yet, and shown whole only past `instant`: late. Several frames in a row, and nothing
                // is in flight now: the rest is the steps'. One is a hiccup: the glide goes on. (First seen past
                // `instant` already shown: betterlink's tick came late, not the frame.)
                late = pendingSeen && now - sentAt > Self.instant ? late + 1 : 0
                if late >= Self.lateFrames { slow = true; done = true; return nil }
                if final { done = true; return nil }
            } else if probing {
                if Self.near(seen.minX, e.minX, 0.5), Self.near(seen.width, e.width, 0.5), Self.near(seen.maxY, e.maxY, 0.5) {
                    // Seen not shown yet, and shown past `instant`: animated or late (one that is seen not shown past
                    // `instant` gives way below). This motion only: the next probes again. First seen past `instant`
                    // already shown: betterlink's tick came late, not the probe, and it landed at once.
                    if pendingSeen, now - sentAt > Self.instant { slow = true; landedLast = true; done = true; return nil }
                    probing = false
                    proven = true
                    // Its size taken as asked, at once: the next left narrowing frame may pair.
                    if !noPairs { pairs = true }
                    expect = nil; asked = nil; took = nil
                    before = seen
                    landedLast = true
                    if final { done = true; return nil }
                } else {
                    pendingSeen = true
                    if now - sentAt > Self.instant { slow = true; probeOut = true; done = true }
                    return nil
                }
            } else {
                pendingSeen = true
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
        var f = end ? (q >= 0.5 ? open : closed) : frame(at: q)
        let starts = q <= 0 && Self.landed(b, closed) ? true : q >= 1 && Self.landed(b, open) ? false : nil
        if !sentAny, !end, Self.landed(f, b), let toOpen = starts {
            // The first frame goes out with the press, as the steps' first call always did (no added latency, Nick):
            // the slide's next point or two toward where it goes, not a tick or more later once it has moved one.
            // Only from a slide's very start, where the window is at its end of it.
            let span = max(abs(open.width - closed.width), abs(open.minX - closed.minX), 1)
            for lead in [1.5, 2.5] {
                f = frame(at: toOpen ? min(1, q + lead / Double(span)) : max(0, q - lead / Double(span)))
                if !Self.landed(f, b) { break }
            }
        }
        // Never back along the slide: a frame behind where the window is (the probe went ahead of the slide) waits.
        if let last = lastProgress, q != last { goingOpen = q > last }
        lastProgress = q
        if !end, let o = goingOpen {
            let going = o ? open : closed
            if abs(f.width - going.width) > abs(b.width - going.width) + 0.5 {
                // Ahead of the slide (the first frame or the probe went out with the press): it waits there, its far
                // edge where the slide has it (a probe, a size alone, moved it): that position goes now.
                let far = side == .left ? f.maxX - b.width : f.minX
                guard !Self.near(b.minX, far, 0.5), Self.near(b.height, f.height, 0.5) else { return nil }
                final = false
                resent = false
                return begin(CGRect(x: far, y: f.maxY - b.height, width: b.width, height: b.height), from: b, now: now)
            }
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
        sentAny = true
        pendingSeen = false
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
        } else if side == .left, f.width < b.width, pairs {
            plan = [.size, .placeAsked, .check]
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
        if unanswered, plan.first == .check {
            // A pair out, and the read after it got no answer (the browser busy now): both are on their way. The
            // size is taken as asked and the frame waited for whole, as widening (`step`).
            plan = []
            stopPairs()
            expect = asked
            return nil
        }
        if unanswered, !widening, asked != nil {
            stopPairs()
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
            case .placeAsked:
                // A pair's position: at the width asked, the size just sent and nothing read since.
                expect = f
                if Self.near(f.minX, b.minX, 0.5) && Self.near(f.maxY, b.maxY, 0.5) { continue }
                return .position(f)
            case .check:
                // The width read after the pair. Taken as asked: the frame is out whole.
                guard let w = took, !Self.near(w, f.width, 0.5) else { continue }
                stopPairs()
                if Self.near(w, b.width, 0.5) {
                    // A size that changed nothing (its minimum already, dropped, or dropped by the position that
                    // followed it): the window back where it was, and the frame asked again, its width read between.
                    let back = CGRect(x: b.minX, y: f.maxY - b.height, width: b.width, height: b.height)
                    plan = [.size, .place]
                    took = nil
                    expect = back
                    if Self.near(back.minX, f.minX, 0.5) { continue }
                    return .position(back)
                }
                // Took part of it (its minimum): the far edge back where the frame has it, at the width taken.
                let at = CGRect(x: f.maxX - w, y: f.maxY - f.height, width: w, height: f.height)
                expect = at
                return .position(at)
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
                    stopPairs()
                    return nil
                }
                let w = took ?? f.width
                if !Self.near(w, f.width, 0.5) { stopPairs() }
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
        // Widening, a size that didn't show at once is late (the window can grow there: a size goes first only
        // where it can, else the position does) and still on its way, moved or not: the steps take it as their own
        // call in flight (sent again if dropped), as after a probe. Started afresh, it would land after their calls
        // and pass for someone else's change (a late browser, a press turning the glide back meanwhile).
        // Taken over by a press, or asked before the glide turned back, it is the press before's: waited for,
        // never sent again.
        if stoppedAtSize, widening, !landedLast {
            guard let c = lastCall, case .size(let f) = c.call, f.width > c.from.width + 0.5 else { return .none }
            return .waits(WindowSteps.inFlight(c.call, at: c.at, from: c.from, seen: seen, changed: changedAt, moved: changedAt > c.at, own: !takenOver && !foreign))
        }
        guard moved else { return .none }
        let resume = WindowSteps.Resume(from: start, seen: seen, at: sentAt, changed: changedAt)
        if resizedItself { return .holds(resume) }
        if landedLast { return final || (stoppedAtSize && !widening) ? .holds(resume) : .none }
        // A size the browser didn't show at once, narrowing: checked as after the steps' own size (its minimum, a
        // stop short).
        if stoppedAtSize { return .holds(resume) }
        guard let c = lastCall else { return .none }
        return .waits(WindowSteps.inFlight(c.call, at: c.at, from: c.from, seen: seen, changed: changedAt, moved: changedAt > c.at))
    }
}
