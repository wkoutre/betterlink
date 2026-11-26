import Foundation

/// Which of a browser's windows are browser windows: the ones with tabs, the
/// only ones that get a sidebar. Decided by what a window is seen to hold and
/// by the browser's own word for it, never by its title or by which browser
/// it is.
///
/// Every window judged here is a standard window with close, minimize, zoom
/// and full screen buttons: a normal window, a popup (an extension's palette),
/// an app window and DevTools on its own all read the same that far (Chrome
/// for Testing 158 and Brave 158, 2026-11-25). What only a normal window has
/// is a group of tabs, with the tabs across the top, in a column or collapsed.
///
/// Not every browser shows one: Dia's own windows have none. So tabs decide
/// only in a browser one of whose windows has been seen with them since it
/// was first watched (`readable`). A browser never seen with tabs keeps every
/// window, as before.
///
/// A window still opening has no tabs yet. It is not known yet, and looked at
/// a few more times (`waits`) before it is taken not to be a browser window.
///
/// The browser's own word comes through the extension, for a window paired
/// with one of the windows it reports (`said`). A window it calls normal is a
/// browser window whatever it shows; one it calls a popup or an app window is
/// not, which is all there is to go by where tabs can't tell. And tabs are
/// only trusted while they agree with it: a native tab view reads as a group
/// of tabs too, so once a window the extension calls normal has had its looks
/// and shown none, tabs no longer decide anything in that browser.
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
        /// Seen with tabs, called normal by the browser, or nothing can tell.
        case browser
        /// Called a popup or an app window by the browser, or looked at as
        /// often as a window is and never seen with tabs.
        case notBrowser
        /// No tabs seen yet with looks still to come, or the browser's word
        /// still awaited.
        case unknown
    }

    /// What the browser calls the window this one is paired with:
    /// `chrome.windows`' "normal", or anything else (popup, app, devtools).
    public enum Word: Equatable, Sendable { case normal, other }

    /// How long after each look without tabs the next one comes: five more
    /// looks over three seconds, close together at first so a window that is
    /// only opening gets its sidebar at once.
    public static let waits: [TimeInterval] = [0.1, 0.2, 0.4, 0.8, 1.5]

    /// How long a new window waits for the browser's word where tabs can't
    /// tell and the extension is connected: twice the moment the pairing
    /// gives a word on the focus to hold. Provisional until the time from a
    /// window appearing to its pairing has been measured.
    public static let wordWait: TimeInterval = 0.6

    /// Whether the extension is connected for this browser, so that a word
    /// can come.
    public var listening = false

    /// Whether tabs tell this browser's windows apart: one of them has been
    /// seen with tabs, and none the browser calls normal has shown none.
    public var readable: Bool { tabsSeen && !tabsMislead }
    private var tabsSeen = false
    private var tabsMislead = false

    private struct Seen: Equatable, Sendable {
        var tabs = false
        /// Looks without tabs since the browser was seen with some.
        var looks = 0
        var word: Word?
        /// Its wait for the browser's word is over.
        var waited = false
    }
    private var seen: [UInt32: Seen] = [:]

    public init() {}

    /// Takes in one look at some windows, by window number. All of a look's
    /// windows count before any is judged, whatever order they were read in.
    public mutating func saw(_ readings: [UInt32: Reading]) {
        for (window, r) in readings {
            var s = seen[window] ?? Seen()
            if r.holdsTabs { s.tabs = true; tabsSeen = true }
            seen[window] = s
        }
        // A look from before the browser was seen with tabs said nothing
        // about the window.
        guard readable else { return }
        for (window, r) in readings where !r.holdsTabs { seen[window, default: Seen()].looks += 1 }
        distrustTabsIfTheyMislead()
    }

    /// Takes in the browser's word for the windows paired now. A window not
    /// named keeps the word it had: one without a sidebar is no longer paired.
    public mutating func said(_ words: [UInt32: Word]) {
        for (window, word) in words { seen[window, default: Seen()].word = word }
        distrustTabsIfTheyMislead()
    }

    /// The wait for a window's word is over (`wordWait` after it appeared).
    public mutating func waited(_ window: UInt32) { seen[window, default: Seen()].waited = true }

    /// Looked at as often as a window is, and never seen with tabs.
    private static func lookedOut(_ s: Seen) -> Bool { !s.tabs && s.looks > waits.count }

    private mutating func distrustTabsIfTheyMislead() {
        if seen.values.contains(where: { $0.word == .normal && Self.lookedOut($0) }) { tabsMislead = true }
    }

    /// Whether nothing is known of the window yet: not looked at, no word.
    public func isNew(_ window: UInt32) -> Bool { seen[window] == nil }

    /// Whether the window has ever been seen with tabs.
    public func sawTabs(in window: UInt32) -> Bool { seen[window]?.tabs ?? false }

    public func kind(of window: UInt32) -> Kind {
        let s = seen[window] ?? Seen()
        // What the window itself shows outweighs a pairing that says popup.
        if s.tabs || s.word == .normal { return .browser }
        if s.word == .other { return .notBrowser }
        if readable { return Self.lookedOut(s) ? .notBrowser : .unknown }
        return listening && !s.waited ? .unknown : .browser
    }

    /// How long until the next look at a window whose tabs haven't been seen.
    /// Nil when there are no more looks: it is known, or looks can't tell.
    /// A window the browser calls normal gets its looks too: they are what
    /// shows whether tabs can be trusted here.
    public func wait(for window: UInt32) -> TimeInterval? {
        let s = seen[window] ?? Seen()
        guard readable, !s.tabs, s.word != .other, !Self.lookedOut(s) else { return nil }
        return s.looks == 0 ? 0 : Self.waits[s.looks - 1]
    }

    /// Whether the window is not known yet for want of the browser's word
    /// alone: no look will tell, and `wordWait` after it appeared it counts
    /// as a browser window (`waited`).
    public func awaitsWord(_ window: UInt32) -> Bool {
        let s = seen[window] ?? Seen()
        return !readable && listening && !s.tabs && s.word == nil && !s.waited
    }

    /// Whether a look at a window that an event merely lists is of use: not
    /// once it has been seen with tabs or has been judged. A window that has
    /// been judged keeps that until an event that can change what it shows
    /// (`startOver`).
    public func needsLook(_ window: UInt32) -> Bool {
        let s = seen[window] ?? Seen()
        return !s.tabs && s.word != .other && !(readable && Self.lookedOut(s))
    }

    /// An event that can change what the window shows (it was resized, as on
    /// leaving full screen, or came back from the Dock): it gets its looks
    /// afresh. A word that it is a popup or an app window is forgotten too:
    /// that word came from a pairing, and a window without a sidebar is paired
    /// no more, so without this one wrong pairing would hold until the window
    /// closes. It is paired again and its new word, or its looks, decide.
    public mutating func startOver(_ window: UInt32) {
        guard seen[window] != nil else { return }
        seen[window]!.looks = 0
        if seen[window]!.word == .other {
            seen[window]!.word = nil
            seen[window]!.waited = false
        }
    }

    /// Forgets a window that has closed.
    public mutating func forget(_ window: UInt32) { seen[window] = nil }

    /// Forgets the windows that are gone.
    public mutating func keep(_ alive: Set<UInt32>) { seen = seen.filter { alive.contains($0.key) } }
}
