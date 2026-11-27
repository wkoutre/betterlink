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
/// - Widening against that edge: a size can't grow a window past its
///   screen's edge (measured on macOS 26 with Chrome for Testing: at x 280,
///   1640 wide on a 1920 screen, asked for 1920 it stayed 1640), so the
///   position goes first, then the size. The frame in between has its right
///   edge in, for as long as the window server shows the position alone.
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
        let grows = right.map { seen.minX + target.width <= $0 + 0.5 } ?? false
        return grows ? [.size(target), .position(target)] : [.position(target), .size(target)]
    }

    /// The calls of `call` from `seen`: a size or a position alone as it is,
    /// a whole frame as `calls(from:to:keep:right:)` orders it.
    public static func expand(_ call: Call, from seen: CGRect, keep: SidebarSide?, right: CGFloat?) -> [Call] {
        if case .frame(let f) = call { return calls(from: seen, to: f, keep: keep, right: right) }
        return [call]
    }

    /// How far the far edge (away from `keep`) of the frame between the
    /// calls is inside where it ends, when it is: only a window widened
    /// against its screen's far edge (the position first). Nil otherwise.
    public static func farEdgeIn(from seen: CGRect, to target: CGRect, keep: SidebarSide, right: CGFloat?) -> CGFloat? {
        guard let b = between(from: seen, calls: calls(from: seen, to: target, keep: keep, right: right)) else { return nil }
        let inside = keep == .left ? target.maxX - b.maxX : b.minX - target.minX
        return inside >= 0.5 ? inside : nil
    }

    /// The frame the window has between the calls, when there are two: what
    /// the window server may show for as long as the first has landed and the
    /// second hasn't.
    public static func between(from seen: CGRect, calls: [Call]) -> CGRect? {
        guard calls.count == 2 else { return nil }
        switch calls[0] {
        case .position(let f): return CGRect(x: f.minX, y: f.maxY - seen.height, width: seen.width, height: seen.height)
        case .size(let f): return CGRect(x: seen.minX, y: seen.maxY - f.height, width: f.width, height: f.height)
        case .frame: return nil
        }
    }
}
