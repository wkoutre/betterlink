import Foundation

/// Which of a browser's own windows each window on screen is, so every window's
/// sidebar shows that window's tabs.
///
/// Never a guess: a click in the sidebar switches, closes and opens tabs, and
/// doing that in another window than the one beside it is worse than showing
/// nothing. And never two windows on one browser window.
///
/// A pairing the frame and title settle between them (this window matches that
/// browser window and neither matches another) is certain, and kept while both
/// exist. What only the focus or a lone frame says is kept too, but gives way to
/// a certain pairing and to what the focus says next: the browser's word and
/// macOS's word for which window is focused arrive a moment apart.
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
        /// reports: an Incognito window it isn't allowed in, or a window of a
        /// profile without the extension.
        case unseen
    }

    private struct Pair { var hit: Hit; var certain: Bool }
    private var pairs: [Int: Pair] = [:]
    private static let tolerance = 40.0

    public init() {}

    /// Whether more evidence (a new title, the focus) can't change this window's pairing.
    public func isCertain(_ id: Int) -> Bool { pairs[id]?.certain ?? false }

    /// The sessions a window of process `pid` can belong to: each browser
    /// profile is its own. One whose browser process isn't known yet is matched
    /// by the browser's name.
    public static func candidates(pid: Int, app: String, in sessions: [BrowserSession]) -> [BrowserSession] {
        let mine = sessions.filter { $0.browserPid == pid }
        return mine.isEmpty ? sessions.filter { $0.browser == app } : mine
    }

    /// Pairs `windows` (every one there is, whatever app is in front) with the
    /// browsers' own windows.
    public mutating func update(_ windows: [Window], in sessions: [BrowserSession]) -> [Int: Found] {
        let alive = Set(windows.map(\.id))
        pairs = pairs.filter { alive.contains($0.key) }
        var found: [Int: Found] = [:]
        for (pid, group) in Dictionary(grouping: windows, by: \.pid) {
            let mine = Self.candidates(pid: pid, app: group[0].app, in: sessions)
            let entries = mine.flatMap { s in
                s.store.orderedWindows.map { Entry(hit: Hit(session: s.id, windowId: $0.id), window: $0.window, title: $0.tabs.first(where: \.active)?.title ?? "") }
            }
            pair(group, with: entries)
            for w in group { found[w.id] = mine.isEmpty ? .notConnected : pairs[w.id].map { .window($0.hit) } ?? .unseen }
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
        /// Both the title and the frame say it is another window.
        func isNot(_ w: Window) -> Bool { titles(w) == false && isAt(w) == false }
    }

    private mutating func pair(_ windows: [Window], with entries: [Entry]) {
        let existing = Set(entries.map(\.hit))
        for w in windows {
            guard let p = pairs[w.id] else { continue }
            let gone = !existing.contains(p.hit)
            if gone || (!p.certain && entries.contains { $0.hit == p.hit && $0.isNot(w) }) { pairs[w.id] = nil }
        }
        // Settled by frame and title. Each one settled can settle another.
        while let (w, e) = only(windows.filter { !isCertain($0.id) }, entries.filter { !claimed($0.hit, certainly: true) },
                                where: { $1.isAt($0) == true && $1.titles($0) == true }) {
            claim(e.hit, for: w.id, certain: true)
        }
        // The browser says which of its windows has focus, and the other
        // profiles' copies of the extension "none of mine", so at most one
        // across them all is focused. It alone tells apart windows at one
        // place with one title.
        let focused = entries.filter(\.window.focused)
        if focused.count == 1, let e = focused.first, let w = windows.first(where: \.focused),
           !isCertain(w.id), !claimed(e.hit, certainly: true), !e.isNot(w) {
            claim(e.hit, for: w.id, certain: false)
        }
        // The frame and title once the windows paired so far are set aside;
        // then, when a title can't be compared, the only window at this frame;
        // then, with no frames to go by, the only window with this title.
        let noFrames = entries.allSatisfy { $0.window.bounds == nil }
        let any: (Window, Entry) -> Bool = { _, _ in true }
        let rules: [(matches: (Window, Entry) -> Bool, and: (Window, Entry) -> Bool)] = [
            ({ $1.isAt($0) == true && $1.titles($0) == true }, any),
            ({ $1.isAt($0) == true }, { $1.titles($0) == nil }),
            ({ ($0.frame == nil || noFrames) && $1.titles($0) == true }, any),
        ]
        for rule in rules {
            while let (w, e) = only(windows.filter { pairs[$0.id] == nil }, entries.filter { !claimed($0.hit) },
                                    where: rule.matches, and: rule.and) {
                claim(e.hit, for: w.id, certain: false)
            }
        }
    }

    /// A window and a browser window that match each other and nothing else,
    /// and for which `and` holds.
    private func only(_ windows: [Window], _ entries: [Entry], where matches: (Window, Entry) -> Bool,
                      and: (Window, Entry) -> Bool = { _, _ in true }) -> (Window, Entry)? {
        for w in windows {
            let hits = entries.filter { matches(w, $0) }
            if hits.count == 1, and(w, hits[0]), windows.filter({ matches($0, hits[0]) }).count == 1 { return (w, hits[0]) }
        }
        return nil
    }

    private func claimed(_ hit: Hit, certainly: Bool = false) -> Bool {
        pairs.values.contains { $0.hit == hit && ($0.certain || !certainly) }
    }

    private mutating func claim(_ hit: Hit, for id: Int, certain: Bool) {
        for (k, p) in pairs where p.hit == hit { pairs[k] = nil }
        pairs[id] = Pair(hit: hit, certain: certain)
    }
}
