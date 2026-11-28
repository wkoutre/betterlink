import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Moving and resizing another app's window to `target`, one Accessibility
/// call at a time, each waited for on screen before the next.
///
/// On macOS 27 a size or position set through Accessibility is animated by
/// the system, and the animation can begin late: reading it back gives the
/// target at once, and the next set cuts the one in flight where it has got
/// to (measured on Nick's laptop, 27.2.1: size then position with no wait
/// left Brave 1871 of 1776 wide; a position then size, at x 15 of 280). So
/// nothing is sent while the window server's frame (what is on screen) is
/// still changing from the last call, and a window is never moved before it
/// has really taken its new size. A call has landed when the window server's
/// frame has reached what it asked, or has changed at least once and then
/// held still for `still` (a narrower size of a show or hide, or of the final
/// target: both, since a browser can take it and then widen itself back to
/// its minimum). A call
/// of a show or hide (or the final target's) held still short of what it
/// asked is sent once more first, since macOS 27 can hold an animation
/// partway: if the window moves again it goes on, and if it stays still
/// another `still` (plus the longest the window took to start on a call of
/// these steps, since that animation too can begin late) it has stopped there.
/// A call taken over (`after:`) that isn't one of these steps' own is the
/// press before's: it is never sent again, nor checked. Held still, it has
/// landed where it holds (the next call, these steps' own, cuts short what
/// is left of it); not started, it is waited for up to the deadline, since
/// it may yet land and these steps' calls are worked out from where the
/// window is. A window that hasn't moved at all since the call
/// hasn't started on it yet: that is waited for, and only `deadline` ends
/// the wait (a call that changes nothing within `patience` is sent once
/// more meanwhile, since a call can be dropped).
///
/// - Narrowing: the size first; once it has landed, the position that keeps
///   the far edge (`keep`) where it was at the width it really took.
/// - Widening: the position first (a window can't grow past its screen's
///   edge from where it is), then the size. A size it doesn't take moves it
///   back where it was, unless the steps are giving the window space back
///   (`retreats` false).
/// - Then the frame is checked, and what is missing asked once more. A size
///   it took only part of and stopped at is its minimum (or a screen's
///   edge): that is not asked again.
/// - `widest`: a size it stops short at, wider than this, ends the steps
///   there (`stoppedShort`), nothing more sent: opening, the sidebar would
///   have less than its least width, and the caller puts the window back at
///   once instead of moving it to keep its far edge first.
/// - With a `deadline`, a change the call in flight can't make is someone
///   else's (the person, or another app): the steps end there
///   (`interrupted`) and nothing more is sent, so their frame stands. A size
///   keeps the window's top left; a position keeps its size and goes from
///   where the window is toward where it was sent, all the way across
///   (macOS doesn't stop a move sideways). Only that call is weighed: every
///   call before it has landed (steps that take over from others wait for
///   their call in flight first), so it is the only one of
///   betterlink's that can be moving the window. Nothing is remembered past
///   the steps.
/// - `resends`: the steps' end, the final target sent whole once more, its
///   size and its position, whatever the window looks like. Accessibility
///   sets are done in order, so a call of betterlink's still on its way
///   (one the cap cut off, or a late browser's) lands before these, and the
///   window ends at the target. Each is waited for as any call, and sent
///   again once when the window hasn't started on it within `patience`
///   (a call can be dropped), or at once when the window already looks
///   done (then its landing can't be seen); nothing ends them early.
///
/// Pure: the caller reads the frame on screen and sends what `step` returns.
public struct WindowSteps: Sendable {
    /// What to send: a size, or a position, each as the frame it gives (Cocoa
    /// coordinates), the window's top edge where `frame` has it.
    public enum Call: Equatable, Sendable {
        case size(CGRect)
        case position(CGRect)
    }

    public let target: CGRect
    /// The sidebar's side: the window's other edge stays where `target` has
    /// it, whatever width it takes. Nil: the origin goes where `target` has it.
    public let keep: SidebarSide?
    /// The widest the window may end at and still be of use; nil: any.
    public let widest: CGFloat?
    /// Widening, a size it doesn't take moves it back where it was.
    public let retreats: Bool
    /// When the steps end, whatever has landed (`capped`): a show or a hide,
    /// all its calls, is given `cap`. Nil: a call that changes nothing
    /// within `patience` is taken as not taken (a drag of the sidebar's edge,
    /// whose next call comes anyway), and nothing is taken as someone else's.
    public let deadline: Double?
    /// The final target sent whole once more (see above).
    public let resends: Bool
    /// A width this window's browser was seen to stop at, asked narrower
    /// (its minimum, as far as anything has shown). With a deadline, a
    /// narrower size that a window no wider than that doesn't move at all is
    /// checked as a stop short is (sent once more after `still`, and still
    /// unmoved another `still` plus the start lag, stopped there) instead of
    /// waited for up to the deadline. The browser is always asked.
    public let stops: CGFloat?
    /// A change the call in flight can't make ends the steps (`interrupted`).
    /// With a `deadline`, always; the final target sent once more, only when
    /// nothing of betterlink's can still be on its way (not after a cap).
    public let watches: Bool
    /// `resends`: every size lands only once it has held still too, not only
    /// a narrower one (the end of a drag, whose last size the window may
    /// look done with before its browser has widened itself back).
    public let settles: Bool
    public private(set) var done = false
    /// Done because something else changed the window (see above).
    public private(set) var interrupted = false
    /// Done because the window stopped short wider than `widest`.
    public private(set) var stoppedShort = false
    /// Done because `deadline` came first.
    public private(set) var capped = false
    /// How long a call that changes nothing is waited for before it is sent
    /// again (with a `deadline`) or taken as not taken: `timeout`, or less
    /// for a browser known to answer quickly (a drag of the sidebar's edge).
    public var patience = WindowSteps.timeout
    /// How far (in points, on every edge) the system may move the window on
    /// its own while these steps carry out a refit (`SidebarInstance`'s, of a
    /// window the person has just tiled) without it counting as someone
    /// else's change: macOS's tiling settles a window it has just tiled by a
    /// point after it reports it at rest (MINI-16 on macOS 27 at 6ebd0da,
    /// 1027 then 1028). 0: none. A change bigger than this is someone else's,
    /// as always; frames within 2 pt are the same (`SidebarGeometry.same`).
    public var slack: CGFloat = 0
    /// The longest any call took to land (its last change), in seconds.
    public private(set) var slowest = 0.0
    /// How many calls moved the window.
    private var moves = 0
    /// Every call that moved the window had landed within `WindowGlide.instant`
    /// of being sent, and one did: this window's sets land at once.
    public var landedAtOnce: Bool { moves > 0 && slowest <= WindowGlide.instant }
    /// The longest the window took to start on a call of these steps (its
    /// first change), in seconds: macOS 27's animation can begin late.
    private var startLag = 0.0

    private enum Phase: Equatable {
        case start
        case movedFirst(from: CGRect)
        case sizing(from: CGRect, movedFirst: CGRect?)
        case placed
    }
    private var phase = Phase.start
    /// The call in flight: when it was sent, the frame at the last look, when
    /// that last changed, the frame it was sent from, and whether the window
    /// has changed since (a change in the very tick it was sent counts); and,
    /// once it was sent again to check a stop short, when, and whether the
    /// window has moved since.
    private var sent: (call: Call, at: Double, last: CGRect, changed: Double, from: CGRect, moved: Bool, checkedAt: Double?, resumed: Bool)?
    /// The call in flight was the steps' these took over from.
    private var inherited = false
    /// And it is not one of these steps' own (a size or a position these
    /// would not ask): the press before's, which the last press overrides.
    /// It is waited for, never sent again and never checked (review of
    /// ce5bf39, F5): held still, it has landed where it holds; not started,
    /// it is waited for up to the deadline.
    private var foreign = false
    /// `resends`: the call in flight was sent again once already.
    private var resent = false
    /// That call, once landed: a size these would ask too is taken as theirs.
    private var adopt: (call: Call, from: CGRect, moved: Bool)?
    private var retried = false
    private var resentSize = false
    /// Where it was put at a size it stopped short at: its minimum.
    private var short: CGRect?
    /// The size didn't move a window already at a width its browser was seen
    /// to stop at (`stops`), sent once more either: it stopped there.
    private var stayed = false
    /// `resends`: the calls still to send, and whether the last was one sent twice.
    private var finals: [Call]?
    private var echoed = false

    /// How long the window must stay still, once it has moved, for a call to
    /// count as landed short of what was asked (a minimum width, a screen's
    /// edge, a browser that overshoots and widens back), and how long a call
    /// that changes nothing is waited for before it is sent again.
    public static let still = 0.15
    public static let timeout = 0.6
    /// The longest a show or a hide may take, every call of it included.
    public static let cap = 3.0

    /// A glide (`WindowGlide`) that moved the window toward `target` and gave
    /// way: the steps go on as though their size had been sent at `at` from
    /// `from` (the window before the glide), the window seen at `seen` and
    /// last changed at `changed`. A size of the glide's still on its way
    /// keeps the window's top left, so it is taken as theirs; held still
    /// short of the target, the size is sent once more and the steps' checks
    /// (a stop short, its minimum, the far edge) are made as after a size.
    public struct Resume: Equatable, Sendable {
        public var from: CGRect
        public var seen: CGRect
        public var at: Double
        public var changed: Double
        /// The window has changed since the call: else it hasn't started on it, and it is waited for (and sent
        /// again every `patience`) as a call of the steps' own that changes nothing.
        public var moved: Bool
        public init(from: CGRect, seen: CGRect, at: Double, changed: Double, moved: Bool = true) {
            self.from = from
            self.seen = seen
            self.at = at
            self.changed = changed
            self.moved = moved
        }
    }

    /// Steps whose one call, `call`, was sent at `at` by someone of
    /// betterlink's other than steps (a glide): to pass as `after` to the
    /// steps that take over, which wait for it and never send it again.
    /// `from`: the window when it was sent; `seen`: now; `changed`: when it
    /// last changed; `moved`: whether it has changed since the call.
    /// `own`: the steps that take over treat it as theirs (sent again if
    /// dropped or held partway), though it isn't what they ask: a glide's
    /// probe of a widening (`WindowGlide`), of the same motion.
    public static func inFlight(_ call: Call, at: Double, from: CGRect, seen: CGRect, changed: Double, moved: Bool, own: Bool = false,
                                then: [Call] = []) -> WindowSteps {
        var w = WindowSteps(target: seen, keep: nil)
        w.sent = (call, at, seen, changed, from, moved, nil, false)
        w.lends = own
        w.then = then
        return w
    }

    /// The calls sent right after the one in flight, in the same go (the
    /// rest of a glide frame: its size after its position, and the position
    /// after that): once that one has landed, each is waited for the same
    /// way in turn, before anything of these steps' own.
    private var then: [Call] = []

    /// Where `c` leaves a window at `r`: a size keeps its top left, a
    /// position its size.
    private static func applying(_ c: Call, to r: CGRect) -> CGRect {
        switch c {
        case .size(let f): CGRect(x: r.minX, y: r.maxY - f.height, width: f.width, height: f.height)
        case .position(let t): CGRect(x: t.minX, y: t.maxY - r.height, width: r.width, height: r.height)
        }
    }

    /// Its call in flight is the taking-over steps' own (`inFlight(own:)`).
    private var lends = false

    /// `after`: the steps these replace, mid-way: their call in flight is
    /// waited for first. `resuming`: a glide's, which these finish.
    public init(target: CGRect, keep: SidebarSide?, widest: CGFloat? = nil, retreats: Bool = true, deadline: Double? = nil,
                resends: Bool = false, watches: Bool = false, settles: Bool = false, stops: CGFloat? = nil, after earlier: WindowSteps? = nil,
                resuming glide: Resume? = nil) {
        self.target = target
        self.keep = keep
        self.widest = widest
        self.retreats = retreats
        self.deadline = resends ? nil : deadline
        self.resends = resends
        self.watches = resends ? watches : deadline != nil
        self.settles = resends && settles
        self.stops = stops
        // Its call in flight is waited for first, as one of these.
        if let earlier, !earlier.done {
            sent = earlier.sent
            then = earlier.then
            inherited = sent != nil
            foreign = earlier.lends ? false : sent.map { !Self.reached($0.call, target) } ?? false
            startLag = earlier.startLag
        } else if let glide {
            phase = .sizing(from: glide.from, movedFirst: nil)
            sent = (.size(target), glide.at, glide.seen, glide.changed, glide.from, glide.moved, nil, false)
        }
    }

    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }
    private static func between(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool { x >= min(a, b) - 1.5 && x <= max(a, b) + 1.5 }

    /// Whether the call in flight, `c`, can take a window at `p` to `seen`:
    /// a size keeps the top left, at any size (a browser takes what it can);
    /// a position keeps the size and goes toward where it was sent.
    private static func can(_ c: Call, from p: CGRect, to seen: CGRect, slack: CGFloat = 0) -> Bool {
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { Self.near(a, b) || abs(a - b) <= slack }
        func between(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool {
            x >= min(a, b) - max(1.5, slack) && x <= max(a, b) + max(1.5, slack)
        }
        switch c {
        case .size: return near(p.minX, seen.minX) && near(p.maxY, seen.maxY)
        case .position(let t):
            return near(p.width, seen.width) && near(p.height, seen.height)
                && between(seen.minX, p.minX, t.minX) && between(seen.maxY, p.maxY, t.maxY)
        }
    }

    private static func narrows(_ c: Call, _ from: CGRect) -> Bool {
        if case .size(let f) = c { f.width < from.width - 1 } else { false }
    }

    private static func reached(_ c: Call, _ seen: CGRect) -> Bool {
        switch c {
        case .size(let f): return near(seen.width, f.width) && near(seen.height, f.height)
        case .position(let f): return near(seen.minX, f.minX) && near(seen.maxY, f.maxY)
        }
    }

    /// The next call, given the window's frame on screen now (`seen`) and the
    /// time; nil while waiting for the last one, or when done.
    public mutating func step(seen: CGRect, now: Double) -> Call? {
        if done { return nil }
        if let deadline, now >= deadline {
            capped = true
            done = true
            return nil
        }
        // Someone else's change is looked for only where a show or hide is carried out.
        let checks = watches
        let capped = deadline != nil
        if var s = sent {
            if seen != s.last, !then.isEmpty, !Self.can(s.call, from: s.last, to: seen, slack: slack) {
                // A later call of its frame already showing (several shown at once, or one after the other between
                // two looks): the ones before it have landed, and that one is under way.
                var landed = Self.applying(s.call, to: s.last)
                var rest = then
                while let n = rest.first {
                    rest.removeFirst()
                    if Self.can(n, from: landed, to: seen, slack: slack) {
                        then = rest
                        s = (n, s.at, landed, s.changed, landed, true, nil, false)
                        sent = s
                        break
                    }
                    landed = Self.applying(n, to: landed)
                }
            }
            if seen != s.last {
                guard !checks || Self.can(s.call, from: s.last, to: seen, slack: slack) else {
                    interrupted = true
                    done = true
                    return nil
                }
                if !s.moved { startLag = max(startLag, now - s.at) }
                if let c = s.checkedAt, !s.resumed { s.resumed = true; startLag = max(startLag, now - c) }
                s.last = seen
                s.changed = now
                s.moved = true
                sent = s
            }
            // Still, once it has moved: landed short. Not moved at all yet: not started.
            // A narrower size of a show or hide, the window already no wider than this window's browser
            // was seen to stop at (`stops`), at or above the width asked: not moving is its answer too.
            let atStop = capped && !foreign && Self.narrows(s.call, s.from) && !s.moved
                && { if case .size(let f) = s.call, let stops, stops >= f.width - 0.5, seen.width <= stops + 0.5 { true } else { false } }()
            let still = (s.moved || atStop) && (s.checkedAt == nil || s.resumed) && now - s.changed >= Self.still
            // Reached, and no longer changing: an animation is never cut short a point from its end. A
            // narrower size, carrying out a show or hide or sending the final target, only once it has
            // held still too: a browser can take it and then widen itself back to its minimum.
            let holds = (capped || resends) && Self.narrows(s.call, s.from)
            // Settling: a size, reached, and nothing changed for `still`, whether it moved or not.
            let settling = settles && { if case .size = s.call { true } else { false } }()
            let arrived = Self.reached(s.call, seen) && s.changed < now && (!holds || still) && (!settling || now - s.changed >= Self.still)
            // Held still short of what it asked, carrying out a show or hide or sending the final target:
            // sent once more, since macOS 27 can hold an animation partway. Moving again, it goes on;
            // still another `still`, it has stopped there (its minimum, or a screen's edge). Not a call
            // taken over that isn't these steps' own: it has landed where it holds, and the next call
            // (these steps' own) cuts short whatever of it is still to come.
            if capped || resends, !foreign, still, !Self.reached(s.call, seen), s.checkedAt == nil {
                s.checkedAt = now
                s.changed = now
                sent = s
                return s.call
            }
            // Once more, it hasn't moved within `still` plus the longest these steps' calls took to start.
            let stopped = s.checkedAt.map { !s.resumed && now - $0 >= Self.still + startLag } ?? false
            if stopped, atStop { stayed = true }
            if !arrived, !still, !stopped {
                guard !s.moved, now - s.at >= patience else { return nil }
                // Not started within `patience`: sent again (a call can be dropped). Carrying out a show
                // or hide, waited for up to the deadline; the final target's, once; a drag's, or one the
                // final target took over, let go (it lands before the final target's all the same). One a
                // show or hide took over that isn't its own: waited for up to the deadline too, never sent
                // again (the press before's, which this press overrides). It may yet land, and these steps'
                // calls are worked out from where the window is, so it isn't let go either.
                if capped, foreign { return nil }
                if capped || (resends && !resent && !inherited) {
                    resent = true
                    s.at = now
                    s.changed = now
                    sent = s
                    return s.call
                }
            }
            if let n = then.first {
                // Its frame's next call, sent with it: waited for in turn, from where this one left the window.
                then.removeFirst()
                if s.moved { slowest = max(slowest, s.changed - s.at); moves += 1 }
                sent = (n, s.at, seen, s.changed, seen, false, nil, false)
                return nil
            }
            sent = nil
            if s.moved { slowest = max(slowest, s.changed - s.at); moves += 1 }
            // A move that stopped short across: macOS doesn't stop a move
            // sideways, so something else stopped it there.
            // Not one taken over that isn't these steps' own: never checked, it may be held partway.
            if checks, !foreign, case .position(let f) = s.call, s.moved, !Self.near(seen.minX, f.minX), !Self.near(seen.minX, s.from.minX),
               abs(seen.minX - f.minX) > slack {
                interrupted = true
                done = true
                return nil
            }
            if inherited {
                inherited = false
                foreign = false
                adopt = (s.call, s.from, s.moved)
            }
        }
        if resends {
            if finals == nil {
                finals = target.width < seen.width - 0.5 ? [.size(target), .position(target)] : [.position(target), .size(target)]
            }
            guard let next = finals?.first else {
                done = true
                return nil
            }
            finals?.removeFirst()
            // There already: its landing can't be seen, so it is sent twice (a call can be dropped).
            if !echoed, Self.reached(next, seen) {
                echoed = true
                finals?.insert(next, at: 0)
            } else {
                echoed = false
            }
            return send(next, seen, now)
        }
        switch phase {
        case .start:
            if SidebarGeometry.same(seen, target) {
                done = true
                return nil
            }
            // The steps taken over from asked this same narrower size, and the window answered: that answer is this one's.
            if let a = adopt, a.moved, case .size(let f) = a.call, abs(f.width - target.width) < 1, abs(f.height - target.height) < 1,
               target.width < a.from.width {
                adopt = nil
                phase = .sizing(from: a.from, movedFirst: nil)
                return step(seen: seen, now: now)
            }
            adopt = nil
            // The size as asked, give or take what browsers round (`SidebarGeometry.same`): only the position.
            if abs(seen.width - target.width) < 2, abs(seen.height - target.height) < 2 {
                phase = .placed
                return send(.position(target), seen, now)
            }
            if target.width < seen.width {
                phase = .sizing(from: seen, movedFirst: nil)
                return send(.size(target), seen, now)
            }
            // Widening: first to where it grows from, at the size it has.
            let first = CGRect(x: target.minX, y: target.maxY - seen.height, width: seen.width, height: seen.height)
            if Self.near(first.minX, seen.minX), Self.near(first.maxY, seen.maxY) {
                phase = .sizing(from: seen, movedFirst: nil)
                return send(.size(target), seen, now)
            }
            phase = .movedFirst(from: seen)
            return send(.position(first), seen, now)
        case .movedFirst(let from):
            phase = .sizing(from: from, movedFirst: from)
            return send(.size(target), seen, now)
        case .sizing(let from, let movedFirst):
            let took = !Self.near(seen.width, from.width) || !Self.near(seen.height, from.height)
            // Seen to stop there before, sent once more, and still unmoved: stopped short where it is.
            if !took, stayed, let widest, target.width <= widest, seen.width > widest + 0.5 {
                stoppedShort = true
                done = true
                return nil
            }
            if !took, !resentSize {
                // Not taken: sent once more (a call can be dropped), before giving up.
                resentSize = true
                return send(.size(target), seen, now)
            }
            guard took else {
                // It didn't take the size: where it was, its position untouched (or, giving space back, where it was put).
                guard retreats, let back = movedFirst, !Self.near(seen.minX, back.minX) || !Self.near(seen.maxY, back.maxY) else {
                    done = true
                    return nil
                }
                phase = .placed
                retried = true
                return send(.position(CGRect(origin: CGPoint(x: back.minX, y: back.maxY - seen.height), size: seen.size)), seen, now)
            }
            // Stopped short, wider than of use: nothing more.
            if let widest, target.width <= widest, seen.width > widest + 0.5 {
                stoppedShort = true
                done = true
                return nil
            }
            let x = keep == .left ? target.maxX - seen.width : target.minX
            let at = CGRect(x: x, y: target.maxY - seen.height, width: seen.width, height: seen.height)
            if abs(seen.width - target.width) >= 2 || abs(seen.height - target.height) >= 2 { short = at }
            phase = .placed
            if Self.near(at.minX, seen.minX), Self.near(at.maxY, seen.maxY) { return step(seen: seen, now: now) }
            return send(.position(at), seen, now)
        case .placed:
            // As asked, or what it could: once more for what is missing.
            if SidebarGeometry.same(seen, target) || retried { done = true; return nil }
            // At the size it stopped short at, where it was put: its minimum, not asked again.
            if let short, Self.near(seen.width, short.width), Self.near(seen.height, short.height),
               Self.near(seen.minX, short.minX), Self.near(seen.maxY, short.maxY) {
                done = true
                return nil
            }
            retried = true
            phase = .start
            return step(seen: seen, now: now)
        }
    }

    private mutating func send(_ c: Call, _ seen: CGRect, _ now: Double) -> Call {
        sent = (c, now, seen, now, seen, false, nil, false)
        inherited = false
        foreign = false
        resent = false
        return c
    }
}
