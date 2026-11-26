import Foundation

/// Whether a window's sidebar is on screen and where among the other windows,
/// from what the window server says: pure, so it is unit tested.
public enum SidebarPresence {
    public enum Relation: Equatable, Sendable { case above, below }

    /// Where the panel sits among the windows: next to its browser window, so
    /// whatever covers that window covers it too. `attached`: beside the window
    /// rather than covering its edge, where only above can be seen.
    /// Always above for now, whatever `attached` says: this is the one place
    /// that decides it, kept for the change that orders an attached panel below.
    public static func relation(attached: Bool) -> Relation { .above }

    public enum Decision: Equatable, Sendable {
        /// Out of sight.
        case away
        /// Left as it is: the window is on a Space that isn't showing, and so
        /// is its panel, which comes and goes with that Space by itself.
        case asleep
        /// On screen. `rehome`: the panel is on another Space than its window
        /// and has to come over. `reorder`: not in its place among the windows.
        case shown(rehome: Bool, reorder: Bool)
    }

    /// - Parameters:
    ///   - window: the browser window's number.
    ///   - panel: the panel's, while it is ordered in (on whatever Space).
    ///   - onScreen: the windows on screen at the normal level, front to back.
    ///   - hidden: hidden with the shortcut, minimized, in native full screen,
    ///     or its app hidden.
    ///   - settled: windows and Spaces have stopped moving, so a panel that
    ///     isn't on screen beside a window that is has been left behind.
    public static func decide(window: UInt32, panel: UInt32?, onScreen: [UInt32], hidden: Bool, attached: Bool,
                              settled: Bool) -> Decision {
        guard !hidden else { return .away }
        let p = panel.flatMap { onScreen.firstIndex(of: $0) }
        guard let w = onScreen.firstIndex(of: window) else {
            // Still here without its window: gone only once that is certain,
            // since a panel taken away no longer comes and goes with its Space.
            return p != nil && settled ? .away : .asleep
        }
        guard let p else { return .shown(rehome: panel != nil && settled, reorder: true) }
        return .shown(rehome: false, reorder: p != (relation(attached: attached) == .above ? w - 1 : w + 1))
    }
}
