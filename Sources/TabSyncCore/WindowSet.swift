import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A slide-over's one set: the calls that take a browser window from where
/// it is to its frame for a show or a hide in one go, sent back to back with
/// no read in between, while the sidebar's panel covers its near edge (Nick's
/// recording of 0.3.34 on macOS 27: Brave can't repaint its page 60 times a
/// second under a set per frame).
///
/// Its size and its position, in the order that never brings the far edge
/// in (the edge away from the sidebar), as far as macOS allows:
///
/// - Narrowing: the position, then the size. The frame in between is the old
///   width at the new place, its right edge pushed out (past the screen's
///   edge if need be: a move isn't limited), never in.
/// - Widening where the window can grow from where it is (its left edge
///   plus the new width within the right edge of the displays side by side
///   at its height, `right`): the size, then the position. The frame in
///   between is pushed out too.
/// - Widening against that edge: a size can't grow a window that is wholly
///   on screen past its screen's edge (measured on macOS 26 with Chrome for
///   Testing: at x 280, 1640 wide on a 1920 screen, asked for 1920 it stayed
///   1640), but it can one already partly off (at x 300, 1640 wide, right
///   edge 1940, a size of 1920 gave right edge 2220). So the window is nudged
///   1 pt right (`nudgeBy`), its far edge 1 pt off the screen, then sized,
///   growing past the edge, then placed: the far edge never comes in (10 of
///   10 runs; the plain position then size showed it in, 5 of 5). Short of
///   the edge, a size first takes it there. The near edge moves 1 pt and
///   back, under the panel.
///
/// A sidebar on the right keeps the window's left edge: there it is a size
/// alone. A frame whose far edge isn't kept (a pair moved back on screen as
/// it closes, a refusal's way back) goes as `WindowSteps` would: narrowing
/// the size first, widening the position first, so the frame between is
/// within one of its ends, never further off screen than both. A call that
/// would change nothing is left out.
public enum WindowSet {
    public typealias Call = WindowSteps.Call

    private static func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.5 }

    /// The calls from `seen` to `target`, in the order they are sent. `keep`:
    /// the sidebar's side, whose far edge the frames share; nil: none kept.
    public static func calls(from seen: CGRect, to target: CGRect, keep: SidebarSide?, right: CGFloat?) -> [Call] {
        let resizes = !(near(seen.width, target.width) && near(seen.height, target.height))
        let moves = !(near(seen.minX, target.minX) && near(seen.maxY, target.maxY))
        guard resizes else { return moves ? [.position(target)] : [] }
        guard moves else { return [.size(target)] }
        let kept = keep.map { abs($0 == .left ? seen.maxX - target.maxX : seen.minX - target.minX) < 1 } ?? false
        guard kept else { return target.width < seen.width ? [.size(target), .position(target)] : [.position(target), .size(target)] }
        if target.width < seen.width - 0.5 { return [.position(target), .size(target)] }
        guard let right else { return [.position(target), .size(target)] }
        // Grows in place, or already partly off the screen's right edge, where a size grows it past the edge.
        if seen.minX + target.width <= right + 0.5 || seen.maxX > right + 0.5 { return [.size(target), .position(target)] }
        // Wholly on screen and too near its right edge to grow in place: to that edge first (unless there),
        // nudged 1 pt past it, then grown past it, then placed.
        var calls: [Call] = []
        var at = seen
        if seen.maxX < right - 0.5 {
            at = CGRect(x: seen.minX, y: seen.maxY - target.height, width: right - seen.minX, height: target.height)
            calls.append(.size(at))
        }
        calls.append(.position(at.offsetBy(dx: right + nudgeBy - at.maxX, dy: 0)))
        return calls + [.size(target), .position(target)]
    }

    /// The right edge of the screen `frame` is on (the one with most of it):
    /// what `calls` weighs growing in place against. Not the displays side by
    /// side: a size can't grow a window wholly on its own screen past that
    /// screen's edge, a seam with another display included.
    public static func screenRight(of frame: CGRect, displays: [CGRect]) -> CGFloat? {
        displays.max { $0.intersection(frame).width * $0.intersection(frame).height < $1.intersection(frame).width * $1.intersection(frame).height }?.maxX
    }

    /// How far past the screen's right edge the window's far edge is nudged
    /// before it is grown past it (`calls`).
    public static let nudgeBy: CGFloat = 1

    /// The calls of `call` from `seen`: a size or a position alone as it is,
    /// a whole frame as `calls(from:to:keep:right:)` orders it.
    public static func expand(_ call: Call, from seen: CGRect, keep: SidebarSide?, right: CGFloat?) -> [Call] {
        if case .frame(let f) = call { return calls(from: seen, to: f, keep: keep, right: right) }
        return [call]
    }

    /// The frame the window has between the calls, when there are two: what
    /// the window server may show for as long as the first has landed and the
    /// second hasn't. With more, the first of them (`betweens`).
    public static func between(from seen: CGRect, calls: [Call]) -> CGRect? { betweens(from: seen, calls: calls).first }

    /// Every frame the window has between the calls, in order: each call's,
    /// but the last's.
    public static func betweens(from seen: CGRect, calls: [Call]) -> [CGRect] {
        var f = seen
        var out: [CGRect] = []
        for c in calls {
            switch c {
            case .position(let p): f = CGRect(x: p.minX, y: p.maxY - f.height, width: f.width, height: f.height)
            case .size(let z): f = CGRect(x: f.minX, y: f.maxY - z.height, width: z.width, height: z.height)
            case .frame(let t): f = t
            }
            out.append(f)
        }
        return Array(out.dropLast())
    }

    /// How far the window's near edge is nudged right before it grows past
    /// its screen's right edge (`calls`), when it is: nil otherwise.
    public static func nudge(from seen: CGRect, to target: CGRect, keep: SidebarSide, right: CGFloat?) -> CGFloat? {
        let calls = calls(from: seen, to: target, keep: keep, right: right)
        guard calls.count > 2, let i = calls.firstIndex(where: { if case .position = $0 { true } else { false } }), i < calls.count - 1 else { return nil }
        let frames = [seen] + betweens(from: seen, calls: calls)
        return frames[i + 1].minX - frames[i].minX
    }
}
