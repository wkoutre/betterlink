import Foundation

/// Which of a browser's own windows each window on screen is, so every window's
/// sidebar shows that window's tabs. Never a guess: a click in the sidebar
/// switches, closes and opens tabs, and doing that in another window than the
/// one beside it is worse than showing nothing.
///
/// Worked out at every look from what is known now: Accessibility (each
/// window's title, frame, and which has the focus), the extension (each browser
/// window's active tab's title, frame, and which has the focus), and the window
/// server (where every window of the browser is, on every Space, without
/// titles). Accessibility lists only the windows on a Space that is showing,
/// and a profile without the extension or an Incognito window is in no
/// session; the two sides' words arrive apart. So nothing is remembered as
/// settled. What is kept from the last look only bridges the moments the
/// sides are out of step:
///
/// 1. An entry is beside at most one window, and a window has at most one.
/// 2. A pairing is never kept, whatever made it, once title and frame both say
///    otherwise.
/// 3. The focus counts only once it has held: the same window and the same
///    browser window focused at two looks `moment` apart (the caller looks
///    again then, `settlesAt`), and never against a title that says no. Then
///    it decides, between look-alikes too, and what it paired is kept through
///    later look-alikes, for as long as it looks right or has not looked
///    wrong for longer than `patience`.
/// 4. A word on the focus that hasn't held changes nothing. Without the
///    focus, a pairing needs title and frame to match, nothing else that is
///    free to match as well, and every other window of the browser at that
///    place to have a browser window of its own reported there: a window
///    there with none could be the one meant. Windows that can't be told
///    apart show nothing.
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
    /// the two sides' words on the focus are usually apart.
    public static let moment = 0.3
    /// How long what the focus paired may look wrong (its title or its frame
    /// saying no) and still be kept through look-alikes: longer than the
    /// browser's titles are ever behind (2 s, `PublishPacer`). A word on the
    /// focus that came later than `moment` can pair a look-alike; that lasts
    /// no longer than this once the two stop looking alike.
    public static let patience = 3.0

    private struct Pair {
        var hit: Hit
        /// The focus paired them, having held: look-alikes cast no doubt on it.
        var byFocus = false
        /// The title has agreed at some look. A pairing made on the frame
        /// alone, for want of a title, is let go when the title says otherwise.
        var titleSeen = false
        /// Since when its title or its frame has said no, without a break.
        var lapsedSince: Double?
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

    /// The smallest a window can be, each way, and still be a browser window:
    /// the helper windows browsers keep at the standard layer are strips the
    /// height of the menu bar (30 pt), bubbles (under 90 pt high) and squares of
    /// 1 and 64 pt (read from Chrome and Dia), and a browser window can't be
    /// made narrower than about 500 pt or lower than about 300. A window
    /// between counts: counting one too many only blanks a sidebar.
    public static let smallest = 100.0

    /// Where each process's windows that aren't followed are, from the window
    /// server's list: only those that could be a browser window (the standard
    /// layer, not smaller than `smallest`).
    public static func unlisted(_ server: [ServerWindow], followed: Set<UInt32>) -> [Int: [WindowBounds]] {
        let could = server.filter { $0.layer == 0 && $0.bounds.width >= smallest && $0.bounds.height >= smallest && !followed.contains($0.number) }
        return Dictionary(grouping: could, by: \.pid).mapValues { $0.map(\.bounds) }
    }

    /// The pairings the focus made, for the trace.
    public var byFocus: [Int: Hit] { pairs.filter(\.value.byFocus).mapValues(\.hit) }

    /// One look, at `now` (seconds on any steady clock): pairs `windows` (every
    /// one followed, whatever app is in front) with the browsers' own windows.
    /// `others`: by process, where its windows that aren't followed are
    /// (`unlisted`).
    public mutating func update(_ windows: [Window], others: [Int: [WindowBounds]], in sessions: [BrowserSession], now: Double) -> [Int: Found] {
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
            let waiting = pair(group, others: others[pid] ?? [], with: entries, pid: pid, now: now)
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
    private mutating func pair(_ windows: [Window], others: [WindowBounds], with entries: [Entry], pid: Int, now: Double) -> Bool {
        let entry = Dictionary(entries.map { ($0.hit, $0) }, uniquingKeysWith: { a, _ in a })
        // A window of the browser, besides `w`, at `e`'s place, that could be
        // the one `e` is and has no browser window of its own reported there.
        // The windows not followed have no titles, so they are counted: as
        // many browser windows reported there as windows, or one of the
        // windows isn't reported and `e` could be anyone's. A followed window
        // whose title says it isn't `e`'s takes no part, and takes one of the
        // browser windows that could be its own with it. With no frames to
        // go by, the same count over the whole browser.
        func unaccounted(_ w: Window, _ e: Entry) -> Bool {
            let place = e.window.bounds
            func there(_ f: WindowBounds?) -> Bool {
                guard let place else { return true }
                return f.map { place.distance(to: $0) <= Self.tolerance } ?? false
            }
            let beside = windows.filter { $0.id != w.id && there($0.frame) }
            let apart = beside.filter { e.titles($0) == false }
            let reported = entries.filter { $0.hit != e.hit && there($0.window.bounds) }
            // Each window that is plainly another has at most one of them.
            let theirs = min(apart.count, reported.filter { o in apart.contains { o.titles($0) != false } }.count)
            return beside.count - apart.count + others.filter(there).count > reported.count - theirs
        }
        // What each window showed at the last look, unless the evidence has
        // turned against it (2): title and frame both, or the title alone
        // where it never agreed and only the frame made the pairing.
        for w in windows {
            guard var p = pairs[w.id] else { continue }
            guard let e = entry[p.hit], !e.isNot(w) else { pairs[w.id] = nil; continue }
            // What the focus paired is kept through look-alikes only while it
            // looks right, or has not looked wrong for long (3).
            if e.titles(w) == false || e.isAt(w) == false {
                let since = p.lapsedSince ?? now
                p.lapsedSince = since
                if now - since >= Self.patience - 1e-9 { p.byFocus = false }
            } else {
                p.lapsedSince = nil
            }
            guard e.titles(w) != false || p.titleSeen || p.byFocus else { pairs[w.id] = nil; continue }
            if e.titles(w) == true { p.titleSeen = true }
            pairs[w.id] = p
        }
        // The focus (3, 4). The browser says which of its windows has it, and
        // the other profiles' copies of the extension "none of mine", so at
        // most one across them all is focused; with another app in front, none.
        var waiting = false
        let focused = entries.filter(\.window.focused)
        if focused.count == 1, let e = focused.first, let w = windows.first(where: \.focused), !e.isNot(w) {
            if focus[pid]?.window != w.id || focus[pid]?.hit != e.hit { focus[pid] = Focus(window: w.id, hit: e.hit, since: now) }
            let since = focus[pid]?.since ?? now
            let same = pairs[w.id].flatMap { $0.hit == e.hit ? $0 : nil }
            if same?.byFocus == true {
                // Paired by the focus already.
            } else if e.titles(w) == false || same?.lapsedSince != nil {
                // Never against a title that says no, and a pairing that
                // looks wrong now is not made the focus's: once it looks right.
                waiting = same == nil
            } else if now - since >= Self.moment - 1e-9 {
                // It has held: this window is that one, whoever looks like it.
                for (k, p) in pairs where p.hit == e.hit && k != w.id { pairs[k] = nil }
                pairs[w.id] = Pair(hit: e.hit, byFocus: true, titleSeen: same?.titleSeen == true || e.titles(w) == true)
            } else {
                waiting = true
                settlesAt = min(settlesAt ?? .infinity, since + Self.moment)
            }
        } else {
            focus[pid] = nil
        }
        // A pairing by looks holds only while nothing else could be meant (4):
        // not once a window with nothing beside it matches its browser window,
        // or a browser window beside nothing matches it, or a window of the
        // browser at that place has no browser window of its own; nor, when
        // it no longer matches by both title and frame, once anything else
        // does. Each one let go can put another in doubt.
        while true {
            let held = Set(pairs.values.map(\.hit))
            let doubted = windows.filter { w in
                guard let p = pairs[w.id], !p.byFocus, let own = entry[p.hit] else { return false }
                let lapsed = !own.matches(w)
                return windows.contains { $0.id != w.id && own.matches($0) && (pairs[$0.id] == nil || lapsed) }
                    || entries.contains { $0.hit != p.hit && $0.matches(w) && (!held.contains($0.hit) || lapsed) }
                    || unaccounted(w, own)
            }
            if doubted.isEmpty { break }
            for w in doubted { pairs[w.id] = nil }
        }
        // New pairings, among the windows with nothing beside them and the
        // browser windows beside nothing, every other window at the place
        // accounted for: by frame and title; then, when a title can't be
        // compared, the only window at this frame; then, with no frames to go
        // by, the only window with this title. Each one made can leave another
        // the only one.
        let noFrames = entries.allSatisfy { $0.window.bounds == nil }
        let any: (Window, Entry) -> Bool = { _, _ in true }
        let rules: [(matches: (Window, Entry) -> Bool, and: (Window, Entry) -> Bool, titleSeen: Bool)] = [
            ({ $1.matches($0) }, any, true),
            ({ $1.isAt($0) == true }, { $1.titles($0) == nil }, false),
            ({ ($0.frame == nil || noFrames) && $1.titles($0) == true }, any, true),
        ]
        for rule in rules {
            while let (w, e) = only(windows.filter { pairs[$0.id] == nil }, entries.filter { e in !pairs.values.contains { $0.hit == e.hit } },
                                    where: rule.matches, and: { rule.and($0, $1) && !unaccounted($0, $1) }) {
                pairs[w.id] = Pair(hit: e.hit, titleSeen: rule.titleSeen)
            }
        }
        // What the focus paired and now looks wrong is looked at again when
        // its time is up.
        for w in windows {
            if let p = pairs[w.id], p.byFocus, let since = p.lapsedSince { settlesAt = min(settlesAt ?? .infinity, since + Self.patience) }
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
