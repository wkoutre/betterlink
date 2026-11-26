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
/// - Then the frame is checked, and what is missing asked once more.
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
    public private(set) var done = false

    private enum Phase: Equatable {
        case start
        case movedFirst(from: CGRect)
        case sizing(from: CGRect, movedFirst: CGRect?)
        case placed
    }
    private var phase = Phase.start
    private var sent: (call: Call, at: Double, last: CGRect, changed: Double)?
    private var retried = false
    private var resentSize = false

    /// How long the window must stay still, once it has moved, for a call to
    /// count as done short of what was asked (a minimum width, a screen's
    /// edge), and the longest a call is waited for when nothing moves.
    public static let still = 0.06
    public static let timeout = 0.6

    public init(target: CGRect, keep: SidebarSide?) {
        self.target = target
        self.keep = keep
    }

    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }

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
            if seen != s.last { s.last = seen; s.changed = now; sent = s }
            // Still, once it has moved: stopped short. Not moved at all yet: waited for, up to the timeout.
            let still = s.changed > s.at && now - s.changed >= Self.still
            guard Self.reached(s.call, seen) || still || now - s.at >= Self.timeout else { return nil }
            sent = nil
        }
        switch phase {
        case .start:
            if SidebarGeometry.same(seen, target) { done = true; return nil }
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
            let x = keep == .left ? target.maxX - seen.width : target.minX
            let at = CGRect(x: x, y: target.maxY - seen.height, width: seen.width, height: seen.height)
            phase = .placed
            if Self.near(at.minX, seen.minX), Self.near(at.maxY, seen.maxY) { return step(seen: seen, now: now) }
            return send(.position(at), seen, now)
        case .placed:
            // As asked, or what it could: once more for what is missing.
            if SidebarGeometry.same(seen, target) || retried { done = true; return nil }
            retried = true
            phase = .start
            return step(seen: seen, now: now)
        }
    }

    private mutating func send(_ c: Call, _ seen: CGRect, _ now: Double) -> Call {
        sent = (c, now, seen, now)
        return c
    }
}
