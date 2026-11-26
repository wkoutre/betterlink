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
/// held still for `still` (a narrower size of a show or hide: both, since a
/// browser can take it and then widen itself back to its minimum). A window that hasn't moved at all since the call
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
///   their call in flight first, as their own), so it is the only one of
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
    /// A change the call in flight can't make ends the steps (`interrupted`).
    /// With a `deadline`, always; the final target sent once more, only when
    /// nothing of betterlink's can still be on its way (not after a cap).
    public let watches: Bool
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
    /// The longest any call took to land (its last change), in seconds.
    public private(set) var slowest = 0.0

    private enum Phase: Equatable {
        case start
        case movedFirst(from: CGRect)
        case sizing(from: CGRect, movedFirst: CGRect?)
        case placed
    }
    private var phase = Phase.start
    /// The call in flight: when it was sent, the frame at the last look, when
    /// that last changed, the frame it was sent from, and whether the window
    /// has changed since (a change in the very tick it was sent counts).
    private var sent: (call: Call, at: Double, last: CGRect, changed: Double, from: CGRect, moved: Bool)?
    /// The call in flight was the steps' these took over from.
    private var inherited = false
    /// `resends`: the call in flight was sent again once already.
    private var resent = false
    /// That call, once landed: a size these would ask too is taken as theirs.
    private var adopt: (call: Call, from: CGRect, moved: Bool)?
    private var retried = false
    private var resentSize = false
    /// Where it was put at a size it stopped short at: its minimum.
    private var short: CGRect?
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

    /// `after`: the steps these replace, mid-way: their call in flight is
    /// waited for first.
    public init(target: CGRect, keep: SidebarSide?, widest: CGFloat? = nil, retreats: Bool = true, deadline: Double? = nil,
                resends: Bool = false, watches: Bool = false, after earlier: WindowSteps? = nil) {
        self.target = target
        self.keep = keep
        self.widest = widest
        self.retreats = retreats
        self.deadline = resends ? nil : deadline
        self.resends = resends
        self.watches = resends ? watches : deadline != nil
        // Its call in flight is waited for first, as one of these.
        if let earlier, !earlier.done {
            sent = earlier.sent
            inherited = sent != nil
        }
    }

    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }
    private static func between(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool { x >= min(a, b) - 1.5 && x <= max(a, b) + 1.5 }

    /// Whether the call in flight, `c`, can take a window at `p` to `seen`:
    /// a size keeps the top left, at any size (a browser takes what it can);
    /// a position keeps the size and goes toward where it was sent.
    private static func can(_ c: Call, from p: CGRect, to seen: CGRect) -> Bool {
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
            if seen != s.last {
                guard !checks || Self.can(s.call, from: s.last, to: seen) else {
                    interrupted = true
                    done = true
                    return nil
                }
                s.last = seen
                s.changed = now
                s.moved = true
                sent = s
            }
            // Still, once it has moved: landed short. Not moved at all yet: not started.
            let still = s.moved && now - s.changed >= Self.still
            // Reached, and no longer changing: an animation is never cut short a point from its end. A
            // narrower size, carrying out a show or hide, only once it has held still too: a browser can
            // take it and then widen itself back to its minimum.
            let holds = capped && Self.narrows(s.call, s.from)
            let arrived = Self.reached(s.call, seen) && s.changed < now && (!holds || still)
            if !arrived, !still {
                guard !s.moved, now - s.at >= patience else { return nil }
                // Not started within `patience`: sent again (a call can be dropped). Carrying out a show
                // or hide, waited for up to the deadline; the final target's, once; a drag's, or one the
                // final target took over, let go (it lands before the final target's all the same).
                if capped || (resends && !resent && !inherited) {
                    resent = true
                    s.at = now
                    s.changed = now
                    sent = s
                    return s.call
                }
            }
            sent = nil
            if s.moved { slowest = max(slowest, s.changed - s.at) }
            // A move that stopped short across: macOS doesn't stop a move
            // sideways, so something else stopped it there.
            if checks, case .position(let f) = s.call, s.moved, !Self.near(seen.minX, f.minX), !Self.near(seen.minX, s.from.minX) {
                interrupted = true
                done = true
                return nil
            }
            if inherited {
                inherited = false
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
        sent = (c, now, seen, now, seen, false)
        resent = false
        return c
    }
}
