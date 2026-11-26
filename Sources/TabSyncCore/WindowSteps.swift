import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Moving and resizing another app's window to `target`, one Accessibility
/// call at a time, each waited for on screen before the next.
///
/// On macOS 27 a size or position set through Accessibility is animated by
/// the system: reading it back gives the target at once, and the next set
/// cuts the one in flight where it has got to (measured on Nick's laptop,
/// 27.2.1: size then position with no wait left Brave 1871 of 1776 wide; a
/// position then size, at x 15 of 280). So nothing is sent while the window
/// server's frame (what is on screen) is still changing from the last call,
/// and a window is never moved before it has really taken its new size:
///
/// - Narrowing: the size first; once it has taken, the position that keeps
///   the far edge (`keep`) where it was at the width it really took. A size
///   it doesn't take, sent twice, leaves the window where it is.
/// - Widening: the position first (a window can't grow past its screen's
///   edge from where it is), then the size. A size it doesn't take moves it
///   back where it was.
/// - Then the frame is checked, and what is missing asked once more. A size
///   it took only part of and stopped at is its minimum (or a screen's
///   edge): that is not asked again, since a browser that has shown it can't
///   go narrower answers the same call the same way, and each ask that
///   changes nothing is waited out (`timeout`).
/// - `widest`: a size it stops short at, wider than this, ends the steps
///   there (`stoppedShort`), nothing more sent: opening, the sidebar would
///   have less than its least width, and the caller puts the window back at
///   once instead of moving it to keep its far edge first.
/// - A change none of the calls can make is someone else's (the person, or
///   another app): the steps end there (`interrupted`) and nothing more is
///   sent, so their frame stands. A size keeps the window's top left; a
///   position keeps its size and goes from where the window is toward where
///   it was sent, all the way across (macOS doesn't stop a move sideways). A
///   call still on its way from steps these took over from (`after`) can
///   land too.
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
    public private(set) var done = false
    /// Done because something else changed the window (see above).
    public private(set) var interrupted = false
    /// Done because the window stopped short wider than `widest`.
    public private(set) var stoppedShort = false

    private enum Phase: Equatable {
        case start
        case movedFirst(from: CGRect)
        case sizing(from: CGRect, movedFirst: CGRect?)
        case placed
    }
    private var phase = Phase.start
    private var sent: (call: Call, at: Double, last: CGRect, changed: Double, from: CGRect)?
    /// The call in flight was the steps' these took over from.
    private var inherited = false
    /// That call, once landed: a size these would ask too is taken as theirs.
    private var adopt: (call: Call, from: CGRect, moved: Bool)?
    private var retried = false
    private var resentSize = false
    /// Calls that may still land: the one in flight, those waited out with
    /// nothing changed (a browser can answer late), and those of the steps
    /// these took over from.
    private var pending: [Call] = []
    /// Where it was put at a size it stopped short at: its minimum.
    private var short: CGRect?

    /// How long the window must stay still, once it has moved, for a call to
    /// count as done short of what was asked (a minimum width, a screen's
    /// edge), and the longest a call is waited for when nothing moves.
    public static let still = 0.06
    public static let timeout = 0.6

    /// `after`: the steps these replace, mid-way: what they sent may still land.
    public init(target: CGRect, keep: SidebarSide?, widest: CGFloat? = nil, after earlier: WindowSteps? = nil) {
        self.target = target
        self.keep = keep
        self.widest = widest
        // Its call in flight is waited for first, as one of these.
        if let earlier, !earlier.done {
            pending = earlier.pending
            sent = earlier.sent
            inherited = sent != nil
        }
    }

    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }
    private static func between(_ x: CGFloat, _ a: CGFloat, _ b: CGFloat) -> Bool { x >= min(a, b) - 1.5 && x <= max(a, b) + 1.5 }

    /// Whether the window going from `p` to `seen` is what a call that may
    /// still land can do: a size keeps the top left, at any size (a browser
    /// takes what it can); a position keeps the size and goes toward where it
    /// was sent. A browser that does two calls in one go changes both.
    private func explains(_ p: CGRect, _ seen: CGRect) -> Bool {
        let samePlace = Self.near(p.minX, seen.minX) && Self.near(p.maxY, seen.maxY)
        let sameSize = Self.near(p.width, seen.width) && Self.near(p.height, seen.height)
        let sized = pending.contains { if case .size = $0 { true } else { false } }
        let placed = pending.contains {
            guard case .position(let t) = $0 else { return false }
            return Self.between(seen.minX, p.minX, t.minX) && Self.between(seen.maxY, p.maxY, t.maxY)
        }
        return (samePlace || placed) && (sameSize || sized)
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
        if var s = sent {
            if seen != s.last {
                guard explains(s.last, seen) else {
                    interrupted = true
                    done = true
                    return nil
                }
                s.last = seen
                s.changed = now
                sent = s
            }
            // Still, once it has moved: stopped short. Not moved at all yet: waited for, up to the timeout.
            let still = s.changed > s.at && now - s.changed >= Self.still
            // Reached, and no longer changing: an animation is never cut short a point from its end.
            let arrived = Self.reached(s.call, seen) && s.changed < now
            guard arrived || still || now - s.at >= Self.timeout else { return nil }
            sent = nil
            // A move that stopped short across: macOS doesn't stop a move
            // sideways, so something else stopped it there.
            if case .position(let f) = s.call, s.changed > s.at, !Self.near(seen.minX, f.minX), !Self.near(seen.minX, s.from.minX) {
                interrupted = true
                done = true
                return nil
            }
            if inherited {
                inherited = false
                adopt = (s.call, s.from, s.changed > s.at)
            }
            // Landed, or stopped: it won't land again. Waited out with nothing changed: it still may.
            if s.changed > s.at, let i = pending.lastIndex(of: s.call) { pending.remove(at: i) }
        }
        switch phase {
        case .start:
            if SidebarGeometry.same(seen, target) { done = true; return nil }
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
                // It didn't take the size: where it was, its position untouched.
                guard let back = movedFirst, !Self.near(seen.minX, back.minX) || !Self.near(seen.maxY, back.maxY) else {
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
        sent = (c, now, seen, now, seen)
        pending.append(c)
        return c
    }
}
