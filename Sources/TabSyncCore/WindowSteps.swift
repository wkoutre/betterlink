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
    /// coordinates), the window's top edge where `frame` has it; or both, the
    /// frame whole, as a size and a position sent back to back in the order
    /// `WindowSet` gives from where the window is (a slide-over's one set).
    public enum Call: Equatable, Sendable {
        case size(CGRect)
        case position(CGRect)
        case frame(CGRect)
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
    /// Every call that moved the window had landed within `instant` of being
    /// sent, and one did: this window's sets land at once.
    public var landedAtOnce: Bool { moves > 0 && slowest <= Self.instant }
    /// Longer than this to show a call: the browser's sets don't land at once.
    public static let instant = 0.05
    /// How many calls `step` has returned: none after the call the steps
    /// were made with (`sending`) is one set and nothing more.
    public private(set) var more = 0
    /// The steps were made with their first call already sent
    /// (`init(sending:)`), it landed at once and whole, and nothing more was
    /// sent: the motion was that one set (no final resend is owed).
    public var clean: Bool { opened && done && more == 0 && !capped && !interrupted && !stoppedShort && landedAtOnce && short == nil }
    private var opened = false
    /// The set's last call, its position, is these steps' to send once its
    /// size has landed (`init(sending:placeFollows:)`), and is part of the set:
    /// a position landing before a size sent ahead of it (a browser that
    /// takes a position at once and a size late) would bring a left hide's
    /// far edge in.
    private var follows = false
    /// A show's set whose narrower size the window doesn't move for at all:
    /// sent once more after `still`, and the window unchanged `unmovedWait`
    /// after that, it has stopped where it is (`stoppedShort`), however little
    /// is known of the browser's minimum (a first show of a browser already
    /// at it covered the page for the whole cap). Any change after the size
    /// sent once more is the normal wait up to the cap.
    private var refusesUnmoved = false
    private var setAt = 0.0
    /// Refused that way: when the set was sent, when its size was sent once
    /// more, and when the window last changed before that (nil: never), for
    /// `trace.log`.
    public private(set) var unmoved: (set: Double, resent: Double, lastChange: Double?)?
    private var lastChangeBeforeResend: Double?
    /// That position is the call in flight.
    private var placing = false
    /// The steps these took over: their set was seen cut short (`partway`),
    /// and the width their window's browser was seen to stop at (`stops`).
    private var earlierCut = false
    private var earlierStops: CGFloat?
    /// Made with their first call already sent (`init(sending:)`): a slide-over's one set.
    public var oneSet: Bool { opened }
    /// That set was seen partway: its position on its way, or cut short by its
    /// size where it began (`WindowSet.between` says which went first). The
    /// browser's sets animate (macOS 27's, or its
    /// enhanced UI on), and the second of a set cuts the first short: its
    /// next show or hide goes a call at a time. A set that shows late, but
    /// whole, is no such sign (MINI-16, 1df43a3: one set 70 ms late).
    public private(set) var partway = false
    private var between: CGRect?
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
    /// A show's size not moved at all, sent once more: how long the window
    /// may stay unchanged after that before the show is refused as stopped
    /// where it is (`init(sending:refusesUnmoved:)`).
    public static let unmovedWait = 0.3

    /// The longest a show or a hide may take, every call of it included.
    public static let cap = 3.0

    /// `after`: the steps these replace, mid-way: their call in flight is
    /// waited for first.
    public init(target: CGRect, keep: SidebarSide?, widest: CGFloat? = nil, retreats: Bool = true, deadline: Double? = nil,
                resends: Bool = false, watches: Bool = false, settles: Bool = false, stops: CGFloat? = nil, after earlier: WindowSteps? = nil) {
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
            inherited = sent != nil
            foreign = sent.map { !Self.reached($0.call, target) } ?? false
            startLag = earlier.startLag
            earlierCut = earlier.partway
            earlierStops = earlier.stops
            // The same show's set, taken over (through a hide's steps, too) by a press that asks the same (a show
            // turned back and pressed again): still refused if it doesn't move, its size already sent once more.
            // A press that asks something else (`foreign`) only waits for it.
            if earlier.refusesUnmoved {
                refusesUnmoved = true
                setAt = earlier.setAt
                lastChangeBeforeResend = earlier.lastChangeBeforeResend
            }
        }
    }

    /// Steps whose first call, `call`, the caller has just sent at `at`, the
    /// window then at `from`: a slide-over's one set (`WindowSet`), a size, a
    /// position or both back to back (`.frame`). They wait for it as their
    /// own (sent again if dropped, checked if it holds still short) and go on
    /// from where it leaves the window, as after their own size: a browser
    /// that stops at its minimum, or stops short, is checked as then.
    public init(target: CGRect, keep: SidebarSide?, widest: CGFloat? = nil, retreats: Bool = true, deadline: Double? = nil,
                stops: CGFloat? = nil, sending call: Call, from: CGRect, at: Double, between: CGRect? = nil, placeFollows: Bool = false,
                refusesUnmoved: Bool = false) {
        self.init(target: target, keep: keep, widest: widest, retreats: retreats, deadline: deadline, stops: stops)
        opened = true
        self.refusesUnmoved = refusesUnmoved
        setAt = at
        self.between = between
        follows = placeFollows
        sent = (call, at, from, at, from, false, nil, false)
        if case .position = call { phase = .placed } else { phase = .sizing(from: from, movedFirst: nil) }
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
        // A size keeps the top left (within `WindowSet`'s nudge, sent before a size that grows a window past its screen's edge).
        case .size: return (near(p.minX, seen.minX) || abs(p.minX - seen.minX) <= WindowSet.nudgeBy + 0.5) && near(p.maxY, seen.maxY)
        case .position(let t):
            return near(p.width, seen.width) && near(p.height, seen.height)
                && between(seen.minX, p.minX, t.minX) && between(seen.maxY, p.maxY, t.maxY)
        case .frame(let t):
            // A position and a size, back to back, either first: there, or the position on its way (the size kept, the
            // left and top edges going toward where they were sent), or the size on its way (the top left kept, where
            // it was or where the position put it), at any width (a browser takes what it can). Where it was takes in
            // `WindowSet`'s nudge, 1 pt right, before a size that grows the window past its screen's edge.
            let nudged = { (a: CGFloat, b: CGFloat) in near(a, b) || abs(a - b) <= WindowSet.nudgeBy + 0.5 }
            let topLeft = (nudged(p.minX, seen.minX) && near(p.maxY, seen.maxY)) || (near(t.minX, seen.minX) && near(t.maxY, seen.maxY))
            let moving = near(p.width, seen.width) && near(p.height, seen.height)
                && between(seen.minX, p.minX, t.minX) && between(seen.maxY, p.maxY, t.maxY)
            return topLeft || moving
        }
    }

    /// A whole frame (`.frame`) whose size asks a change the window hasn't
    /// begun to make, its place landed (a browser that takes a position at
    /// once and a size late). Not its place unstarted, its size landed: under
    /// an animation (macOS 27's) the size cuts the place short where it
    /// began, and the place never comes.
    private static func halfUnstarted(_ c: Call, from: CGRect, seen: CGRect) -> Bool {
        guard case .frame(let f) = c else { return false }
        let sized = !near(f.width, from.width) || !near(f.height, from.height)
        return sized && near(seen.width, from.width) && near(seen.height, from.height)
    }

    /// The size a call asks, if it asks one.
    private static func size(of c: Call) -> CGRect? {
        switch c {
        case .size(let f), .frame(let f): f
        case .position: nil
        }
    }

    private static func narrows(_ c: Call, _ from: CGRect) -> Bool {
        size(of: c).map { $0.width < from.width - 1 } ?? false
    }

    private static func reached(_ c: Call, _ seen: CGRect) -> Bool {
        switch c {
        case .size(let f): return near(seen.width, f.width) && near(seen.height, f.height)
        case .position(let f): return near(seen.minX, f.minX) && near(seen.maxY, f.maxY)
        case .frame(let f): return near(seen.width, f.width) && near(seen.height, f.height) && near(seen.minX, f.minX) && near(seen.maxY, f.maxY)
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
            if seen != s.last {
                guard !checks || Self.can(s.call, from: s.last, to: seen, slack: slack) else {
                    interrupted = true
                    done = true
                    return nil
                }
                if opened, moves == 0, more == 0 {
                    // A position on its way (its left edge between where it was and where it was sent), or, where the
                    // position goes first, a size that landed before it (the position cut short where it began). A
                    // browser that stops at its minimum, its position landed, is neither.
                    let from = s.from
                    let across = abs(seen.minX - from.minX) > WindowSet.nudgeBy + 0.5 && !Self.near(seen.minX, target.minX)
                    let positionFirst = between.map { Self.near($0.minX, target.minX) && !Self.near(from.minX, target.minX) } ?? false
                    let cut = positionFirst && Self.near(seen.minX, from.minX) && !Self.near(seen.width, from.width)
                    if across || cut { partway = true }
                }
                if !s.moved { startLag = max(startLag, now - s.at) }
                if let c = s.checkedAt, !s.resumed { s.resumed = true; startLag = max(startLag, now - c) }
                s.last = seen
                s.changed = now
                s.moved = true
                sent = s
            }
            // A show's narrower size not moved at all (`refusesUnmoved`).
            if refusesUnmoved, !foreign, Self.narrows(s.call, s.from), Self.near(seen.width, s.from.width), Self.near(seen.height, s.from.height) {
                if let c = s.checkedAt {
                    if s.changed <= c + 1e-9 {
                        guard now - c >= Self.unmovedWait - 1e-9 else { return nil }
                        unmoved = (setAt, c, lastChangeBeforeResend)
                        stoppedShort = true
                        done = true
                        return nil
                    }
                } else {
                    guard now - s.changed >= Self.still - 1e-9 else { return nil }
                    lastChangeBeforeResend = s.moved ? s.changed : nil
                    s.checkedAt = now
                    s.changed = now
                    sent = s
                    more += 1
                    if case .frame(let f) = s.call { return .size(f) }
                    return s.call
                }
            }
            // Still, once it has moved: landed short. Not moved at all yet: not started.
            // A narrower size of a show or hide, the window already no wider than this window's browser
            // was seen to stop at (`stops`), at or above the width asked: not moving is its answer too.
            let atStop = capped && !foreign && Self.narrows(s.call, s.from) && !s.moved
                && { if let f = Self.size(of: s.call), let stops, stops >= f.width - 0.5, seen.width <= stops + 0.5 { true } else { false } }()
            // A whole frame taken over from the press before, half of it landed and the other half not started (a
            // browser that takes a position at once and a size late, as Chromium often does): not started either,
            // and waited for as such, since its other half may still land (the guard at seed 20261126: the new
            // press's calls went out while the size was on its way, and it landed on top of them).
            // Not one seen cut short (its place cut where it began by its size, under an animation), whose other
            // half never comes; nor a narrower size the window is already at its browser's minimum for.
            let atMinimum = Self.size(of: s.call).map { f in earlierStops.map { f.width < s.from.width - 1 && seen.width <= $0 + 0.5 } ?? false } ?? false
            let halfWaits = foreign && !earlierCut && !atMinimum && Self.halfUnstarted(s.call, from: s.from, seen: seen)
            let started = s.moved && !halfWaits
            let still = (started || atStop) && (s.checkedAt == nil || s.resumed) && now - s.changed >= Self.still
            // Reached, and no longer changing: an animation is never cut short a point from its end. A
            // narrower size, carrying out a show or hide or sending the final target, only once it has
            // held still too: a browser can take it and then widen itself back to its minimum.
            let holds = (capped || resends) && Self.narrows(s.call, s.from)
            // Settling: a size, reached, and nothing changed for `still`, whether it moved or not.
            let settling = settles && Self.size(of: s.call) != nil
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
                more += 1
                // A whole frame held still: its size, which is what an animation holds partway (its place, if missing,
                // goes after, as after a size); sent whole, a position cut short the first time would move it again.
                if case .frame(let f) = s.call { return .size(f) }
                return s.call
            }
            // Once more, it hasn't moved within `still` plus the longest these steps' calls took to start.
            // (Its size sent once more by the steps taken over, and still unstarted: waited for all the same.)
            // Nor one taken over that hasn't moved at all: not started, it is waited for up to the cap (seed 6221202,
            // case 11: a busy browser's size, sent once more by the show, landed after the hide had gone on).
            let stopped = !halfWaits && !(foreign && !s.moved) && (s.checkedAt.map { !s.resumed && now - $0 >= Self.still + startLag } ?? false)
            if stopped, atStop { stayed = true }
            if !arrived, !still, !stopped {
                guard !started, now - s.at >= patience else { return nil }
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
                    more += 1
                    return s.call
                }
            }
            sent = nil
            // The set's own position, sent once its size landed (`follows`): its time behind the window's queue,
            // held by the browser answering the size, is the size's, not a sign the browser's sets don't land at once.
            if s.moved { if !placing { slowest = max(slowest, s.changed - s.at) }; moves += 1 }
            placing = false
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
            if let a = adopt, a.moved, let f = Self.size(of: a.call), abs(f.width - target.width) < 1, abs(f.height - target.height) < 1,
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
            let place = send(.position(at), seen, now)
            // The set's own position: not a call more than the set.
            if follows { follows = false; more -= 1; placing = true }
            return place
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
        more += 1
        sent = (c, now, seen, now, seen, false, nil, false)
        inherited = false
        foreign = false
        resent = false
        return c
    }
}
