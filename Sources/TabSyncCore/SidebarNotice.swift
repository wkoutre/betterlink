import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The short note shown when a sidebar can't open beside its window, and
/// where it goes. Pure, so the decision and the words are unit tested; the
/// window that shows it is the app's (SidebarNoticeWindow).
public enum SidebarNotice: Equatable, Sendable {
    /// The browser stopped short: it left the sidebar less than its least width.
    case noRoom
    /// The browser took no size at all.
    case noSize

    /// Why the sidebar didn't open, from what the browser did with the frame
    /// it was given (`frame`, the window's with the sidebar closed) and the
    /// width it ended at; nil when the sidebar has its room.
    public static func refusal(frame: CGRect, took width: CGFloat) -> SidebarNotice? {
        let room = frame.width - width
        guard room < SidebarGeometry.widths.lowerBound - 0.5 else { return nil }
        return abs(width - frame.width) < 2 ? .noSize : .noRoom
    }

    /// What the note says, in plain words.
    public var text: String {
        switch self {
        case .noRoom: "There isn't room for the sidebar beside this window. Make the window wider."
        case .noSize: "This window didn't make room for the sidebar. Resize it a little and try again."
        }
    }

    /// How long it stays before it fades, in seconds.
    public static let duration = 3.0

    /// Where a note of `size` goes: centered on the window, a little below its
    /// top edge (Cocoa coordinates), and kept inside `visible`, the part of
    /// the window's display windows are given.
    public static func frame(size: CGSize, window: CGRect, visible: CGRect) -> CGRect {
        let inset: CGFloat = 56 // below a browser's tab strip and toolbar
        var f = CGRect(x: (window.midX - size.width / 2).rounded(), y: (window.maxY - inset - size.height).rounded(),
                       width: size.width, height: size.height)
        f.origin.x = min(max(f.minX, visible.minX + 8), visible.maxX - 8 - size.width)
        f.origin.y = min(max(f.minY, visible.minY + 8), visible.maxY - 8 - size.height)
        return f
    }
}
