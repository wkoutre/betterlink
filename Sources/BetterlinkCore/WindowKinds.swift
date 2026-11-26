import Foundation

/// Which of a browser's windows are browser windows: the ones with tabs, the
/// only ones that get a sidebar. Decided by what a window is seen to hold,
/// never by its title or by which browser it is.
///
/// Every window judged here is a standard window with close, minimize, zoom
/// and full screen buttons: a normal window, a popup (an extension's palette),
/// an app window and DevTools on its own all read the same that far (Chrome
/// for Testing 158 and Brave 158, 2026-11-25). What only a normal window has
/// is a group of tabs, with the tabs across the top, in a column or collapsed.
///
/// Not every browser shows one: Dia's own windows have none. So the rule holds
/// only in a browser one of whose windows has been seen with tabs since it
/// was first watched. A browser never seen with one keeps every window, as
/// before.
///
/// A window still opening has no tabs yet. It is not known yet, and looked at
/// a few more times (`waits`) before it is taken not to be a browser window.
public struct WindowKinds: Equatable, Sendable {
    /// One look at a window, pages skipped: its tab groups (AXTabGroup) and
    /// the tabs (AXTabButton) in them. A look stops at the first tab.
    public struct Reading: Equatable, Sendable {
        public var tabGroups: Int
        public var tabs: Int
        public init(tabGroups: Int, tabs: Int) { self.tabGroups = tabGroups; self.tabs = tabs }
        public var holdsTabs: Bool { tabGroups > 0 && tabs > 0 }
    }

    public enum Kind: Equatable, Sendable {
        /// Seen with tabs, or its browser never shows any.
        case browser
        /// Looked at as often as a window is, and never seen with tabs.
        case notBrowser
        /// No tabs seen yet, and looks still to come.
        case unknown
    }

    /// How long after each look without tabs the next one comes: five more
    /// looks over three seconds, close together at first so a window that is
    /// only opening gets its sidebar at once.
    public static let waits: [TimeInterval] = [0.1, 0.2, 0.4, 0.8, 1.5]

    /// Whether one of the browser's windows has been seen with tabs.
    public private(set) var readable = false

    private struct Seen: Equatable, Sendable {
        var tabs = false
        /// Looks without tabs since the browser was seen with some.
        var looks = 0
    }
    private var seen: [UInt32: Seen] = [:]

    public init() {}

    /// Takes in one look at some windows, by window number. All of a look's
    /// windows count before any is judged, whatever order they were read in.
    public mutating func saw(_ readings: [UInt32: Reading]) {
        for (window, r) in readings where r.holdsTabs {
            seen[window, default: Seen()].tabs = true
            readable = true
        }
        // A look from before the browser was seen with tabs said nothing
        // about the window.
        guard readable else { return }
        for (window, r) in readings where !r.holdsTabs { seen[window, default: Seen()].looks += 1 }
    }

    /// Whether the window has ever been seen with tabs.
    public func sawTabs(in window: UInt32) -> Bool { seen[window]?.tabs ?? false }

    public func kind(of window: UInt32) -> Kind {
        if sawTabs(in: window) || !readable { return .browser }
        return (seen[window]?.looks ?? 0) > Self.waits.count ? .notBrowser : .unknown
    }

    /// How long until the next look at a window not known yet. Nil when it is
    /// known: no more looks.
    public func wait(for window: UInt32) -> TimeInterval? {
        guard kind(of: window) == .unknown else { return nil }
        let looks = seen[window]?.looks ?? 0
        return looks == 0 ? 0 : Self.waits[looks - 1]
    }

    /// An event has named the window again (it has the focus, another window
    /// opened, another Space shows): it gets its looks afresh.
    public mutating func startOver(_ window: UInt32) { seen[window]?.looks = 0 }

    /// Forgets the windows that are gone.
    public mutating func keep(_ alive: Set<UInt32>) { seen = seen.filter { alive.contains($0.key) } }
}
