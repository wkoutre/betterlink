import Foundation

/// Which of a browser's own windows each window on screen is, so every window's
/// sidebar shows that window's tabs. Never a guess: a click in the sidebar
/// switches, closes and opens tabs, and doing that in another window than the
/// one beside it is worse than showing nothing.
///
/// Worked out at every look from what the two sides say now: Accessibility
/// (each window's title, frame, and which has the focus) and the extension
/// (each browser window's active tab's title, frame, and which has the focus).
/// The windows known here are never all there are (Accessibility lists only
/// those on a Space that is showing, and a profile without the extension or an
/// Incognito window is in no session), and the two sides' words arrive apart.
/// So nothing is remembered as settled. What is kept from the last look only
/// bridges the moments the two sides are out of step:
///
/// 1. An entry is beside at most one window, and a window has at most one.
/// 2. A pairing is never kept, whatever made it, once title and frame both say
///    otherwise.
/// 3. The focus counts only once it has held: the same window and the same
///    browser window focused at two looks `moment` apart (the caller looks
///    again then, `settlesAt`). Then it decides, between look-alikes too, and
///    what it paired is kept through later look-alikes.
/// 4. A word on the focus that hasn't held changes nothing. Windows, or
///    browser windows, that can't be told apart and that the focus hasn't
///    settled show nothing.
/// 5. Being out of step blanks nothing: a pairing that title or frame still
///    supports stays through moves, new titles and a stale word on the focus.
public struct WindowPairing: Sendable {
    /// A browser window on this Mac, as Accessibility has it.
    public struct Window: Equatable, Sendable {
        public var id: Int
        public var pid: Int
        /// The browser's name, for a session whose process isn't known yet.
        public var app: String
        /// Accessibility coordinates.
        public var frame: WindowBounds?
        /// Chromium starts it with the active tab's title.
        public var title: String
        /// Whether it is its browser's focused window.
        public var focused: Bool

        public init(id: Int, pid: Int, app: String, frame: WindowBounds?, title: String, focused: Bool = false) {
            self.id = id; self.pid = pid; self.app = app; self.frame = frame; self.title = title; self.focused = focused
        }
    }

    public struct Hit: Hashable, Sendable {
        public var session: String
        public var windowId: Int
        public init(session: String, windowId: Int) { self.session = session; self.windowId = windowId }
    }

    /// What the sidebar may show for a window.
    public enum Found: Equatable, Sendable {
        case window(Hit)
        /// No copy of the extension is connected for this browser.
        case notConnected
        /// The browser is connected, but this window is not one the extension
        /// reports (an Incognito window it isn't allowed in, or a window of a
        /// profile without the extension), or it can't be told from another.
        case unseen
        /// Not yet: a word on the focus is being given its moment to hold.
        case waiting
    }

    /// How long a word on the focus must hold before it counts: longer than
    /// the two sides' words on the focus are ever apart.
    public static let moment = 0.3

    private struct Pair {
        var hit: Hit
        /// The focus paired them, having held: look-alikes cast no doubt on it.
        var byFocus = false
        /// The title has agreed at some look. A pairing made on the frame
        /// alone, for want of a title, is let go when the title says otherwise.
        var titleSeen = false
    }
    /// What each window showed at the last look.
    private var pairs: [Int: Pair] = [:]
    private struct Focus: Sendable { var window: Int; var hit: Hit; var since: Double }
    /// The focus as both sides had it at the last look, by process.
    private var focus: [Int: Focus] = [:]
    /// When a word on the focus will have held: the caller looks again then.
    public private(set) var settlesAt: Double?

    public init() {}

    /// The sessions a window of process `pid` can belong to: each browser
    /// profile is its own. One whose browser process isn't known yet is matched
    /// by the browser's name.
    public static func candidates(pid: Int, app: String, in sessions: [BrowserSession]) -> [BrowserSession] {
        let mine = sessions.filter { $0.browserPid == pid }
        return mine.isEmpty ? sessions.filter { $0.browser == app } : mine
    }

    /// A window as the window server lists it: every window of every process on
    /// every Space, with no titles (those would need Screen Recording).
    public struct ServerWindow: Equatable, Sendable {
        public var number: UInt32
        public var pid: Int
        public var layer: Int
        public var bounds: WindowBounds
        public init(number: UInt32, pid: Int, layer: Int, bounds: WindowBounds) {
            self.number = number; self.pid = pid; self.layer = layer; self.bounds = bounds
        }
    }

    /// For the tests of the rules to come: nothing is left out yet.
    public static func unlisted(_ server: [ServerWindow], followed: Set<UInt32>) -> [Int: [WindowBounds]] {
        Dictionary(grouping: server, by: \.pid).mapValues { $0.map(\.bounds) }
    }
    public static let patience = 3.0
    public var byFocus: [Int: Hit] { pairs.filter(\.value.byFocus).mapValues(\.hit) }
    public mutating func update(_ windows: [Window], others: [Int: [WindowBounds]], in sessions: [BrowserSession], now: Double) -> [Int: Found] {
        update(windows, in: sessions, now: now)
    }

    /// One look, at `now` (seconds on any steady clock): pairs `windows` (every
    /// one there is, whatever app is in front) with the browsers' own windows.
    public mutating func update(_ windows: [Window], in sessions: [BrowserSession], now: Double) -> [Int: Found] {
        let groups = Dictionary(grouping: windows, by: \.pid)
        pairs = pairs.filter { p in windows.contains { $0.id == p.key } }
        focus = focus.filter { groups[$0.key] != nil }
        settlesAt = nil
        var found: [Int: Found] = [:]
        for (pid, group) in groups {
            let mine = Self.candidates(pid: pid, app: group[0].app, in: sessions)
            let entries = mine.flatMap { s in
                s.store.orderedWindows.map { Entry(hit: Hit(session: s.id, windowId: $0.id), window: $0.window, title: $0.tabs.first(where: \.active)?.title ?? "") }
            }
            let waiting = pair(group, with: entries, pid: pid, now: now)
            for w in group {
                found[w.id] = mine.isEmpty ? .notConnected : pairs[w.id].map { .window($0.hit) } ?? (waiting ? .waiting : .unseen)
            }
        }
        return found
    }

    private struct Entry {
        var hit: Hit
        var window: BrowserWindow
        /// The active tab's.
        var title: String

        /// Nil when there is no title to compare (a page still loading).
        func titles(_ w: Window) -> Bool? { w.title.isEmpty || title.isEmpty ? nil : w.title.hasPrefix(title) }
        func isAt(_ w: Window) -> Bool? {
            guard let f = w.frame, let b = window.bounds else { return nil }
            return b.distance(to: f) <= tolerance
        }
        /// Both the title and the frame say it is this window.
        func matches(_ w: Window) -> Bool { isAt(w) == true && titles(w) == true }
        /// Both the title and the frame say it is another window.
        func isNot(_ w: Window) -> Bool { titles(w) == false && isAt(w) == false }
    }
    private static let tolerance = 40.0

    /// One process's windows. True while a word on the focus is waited on.
    private mutating func pair(_ windows: [Window], with entries: [Entry], pid: Int, now: Double) -> Bool {
        let entry = Dictionary(entries.map { ($0.hit, $0) }, uniquingKeysWith: { a, _ in a })
        // What each window showed at the last look, unless the evidence has
        // turned against it (2): title and frame both, or the title alone
        // where it never agreed and only the frame made the pairing.
        for w in windows {
            guard var p = pairs[w.id] else { continue }
            guard let e = entry[p.hit], !e.isNot(w), e.titles(w) != false || p.titleSeen || p.byFocus else { pairs[w.id] = nil; continue }
            if e.titles(w) == true { p.titleSeen = true; pairs[w.id] = p }
        }
        // The focus (3, 4). The browser says which of its windows has it, and
        // the other profiles' copies of the extension "none of mine", so at
        // most one across them all is focused; with another app in front, none.
        var waiting = false
        let focused = entries.filter(\.window.focused)
        if focused.count == 1, let e = focused.first, let w = windows.first(where: \.focused) {
            if focus[pid]?.window != w.id || focus[pid]?.hit != e.hit { focus[pid] = Focus(window: w.id, hit: e.hit, since: now) }
            let since = focus[pid]?.since ?? now
            if e.isNot(w) {
                // Not this window, whatever the focus says (2).
            } else if now - since >= Self.moment - 1e-9 {
                // It has held: this window is that one, whoever looks like it.
                let seen = pairs[w.id].map { $0.hit == e.hit && $0.titleSeen } ?? false
                for (k, p) in pairs where p.hit == e.hit && k != w.id { pairs[k] = nil }
                pairs[w.id] = Pair(hit: e.hit, byFocus: true, titleSeen: seen || e.titles(w) == true)
            } else if pairs[w.id].map({ $0.hit != e.hit || !$0.byFocus }) ?? true {
                waiting = true
                settlesAt = min(settlesAt ?? .infinity, since + Self.moment)
            }
        } else {
            focus[pid] = nil
        }
        // A pairing by looks holds only while nothing else could be meant (4):
        // not once a window with nothing beside it matches its browser window,
        // or a browser window beside nothing matches it; nor, when it no
        // longer matches by both title and frame, once anything else does.
        // Each one let go can put another in doubt.
        while true {
            let held = Set(pairs.values.map(\.hit))
            let doubted = windows.filter { w in
                guard let p = pairs[w.id], !p.byFocus, let own = entry[p.hit] else { return false }
                let lapsed = !own.matches(w)
                return windows.contains { $0.id != w.id && own.matches($0) && (pairs[$0.id] == nil || lapsed) }
                    || entries.contains { $0.hit != p.hit && $0.matches(w) && (!held.contains($0.hit) || lapsed) }
            }
            if doubted.isEmpty { break }
            for w in doubted { pairs[w.id] = nil }
        }
        // New pairings, among the windows with nothing beside them and the
        // browser windows beside nothing: by frame and title; then, when a
        // title can't be compared, the only window at this frame; then, with
        // no frames to go by, the only window with this title. Each one made
        // can leave another the only one.
        let noFrames = entries.allSatisfy { $0.window.bounds == nil }
        let any: (Window, Entry) -> Bool = { _, _ in true }
        let rules: [(matches: (Window, Entry) -> Bool, and: (Window, Entry) -> Bool, titleSeen: Bool)] = [
            ({ $1.matches($0) }, any, true),
            ({ $1.isAt($0) == true }, { $1.titles($0) == nil }, false),
            ({ ($0.frame == nil || noFrames) && $1.titles($0) == true }, any, true),
        ]
        for rule in rules {
            while let (w, e) = only(windows.filter { pairs[$0.id] == nil }, entries.filter { e in !pairs.values.contains { $0.hit == e.hit } },
                                    where: rule.matches, and: rule.and) {
                pairs[w.id] = Pair(hit: e.hit, titleSeen: rule.titleSeen)
            }
        }
        return waiting
    }

    /// A window and a browser window that match each other and nothing else,
    /// and for which `and` holds.
    private func only(_ windows: [Window], _ entries: [Entry], where matches: (Window, Entry) -> Bool,
                      and: (Window, Entry) -> Bool) -> (Window, Entry)? {
        for w in windows {
            let hits = entries.filter { matches(w, $0) }
            if hits.count == 1, and(w, hits[0]), windows.filter({ matches($0, hits[0]) }).count == 1 { return (w, hits[0]) }
        }
        return nil
    }
}
