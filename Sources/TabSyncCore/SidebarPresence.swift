import Foundation

/// Whether a window's sidebar is on screen and where among the other windows,
/// from what the window server says: pure, so it is unit tested.
public enum SidebarPresence {
    public enum Relation: Equatable, Sendable { case above, below }

    /// Where the panel sits among the windows: next to its browser window, so
    /// whatever covers that window covers it too. `attached`: beside the window
    /// rather than covering its edge, where only above can be seen.
    public static func relation(attached: Bool) -> Relation { .above }

    public enum Decision: Equatable, Sendable {
        /// Out of sight.
        case away
        /// The window is on a Space that isn't showing, and so is its panel,
        /// which comes and goes with that Space by itself.
        case asleep
        /// On screen. `rehome`: the panel is on another Space than its window
        /// and has to come over. `reorder`: not in its place among the windows.
        case shown(rehome: Bool, reorder: Bool)
    }

    /// - Parameters:
    ///   - window: the browser window's number; nil when not known, and then
    ///     there is nothing to sit next to.
    ///   - panel: the panel's, while it is ordered in (on whatever Space).
    ///   - onScreen: the windows on screen at the normal level, front to back.
    ///   - hidden: hidden with the shortcut, minimized, in native full screen,
    ///     or its app hidden.
    ///   - mayRehome: the Spaces have settled, so a panel that isn't on screen
    ///     beside a window that is has been left behind.
    public static func decide(window: UInt32?, panel: UInt32?, onScreen: [UInt32], hidden: Bool, attached: Bool,
                              mayRehome: Bool) -> Decision {
        guard !hidden, let window else { return .away }
        guard let w = onScreen.firstIndex(of: window) else {
            return panel.map { onScreen.contains($0) } ?? false ? .away : .asleep
        }
        guard let panel, let p = onScreen.firstIndex(of: panel) else {
            return .shown(rehome: panel != nil && mayRehome, reorder: true)
        }
        return .shown(rehome: false, reorder: p != (relation(attached: attached) == .above ? w - 1 : w + 1))
    }
}
