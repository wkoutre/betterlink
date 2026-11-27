import Foundation

/// Finding an open tab by typing, across every connected browser and profile:
/// the Find Tab panel and `betterlink tabs find`.
///
/// Every word typed must appear in the tab's title or address, in any order and
/// case. Tabs whose title starts with what was typed come first, then those with
/// a word of the title starting with it, then the rest; ties keep the order the
/// tabs were given in (browser by browser, window by window, left to right).
public enum TabSearch {
    /// One open tab in one connected browser profile.
    public struct Item: Equatable, Sendable {
        public var socketPath: String
        public var tab: Tab
        public init(socketPath: String, tab: Tab) { self.socketPath = socketPath; self.tab = tab }
    }

    /// Every tab of every session, in the order the search keeps for ties.
    public static func items(_ sessions: [BrowserSession]) -> [Item] {
        sessions.flatMap { s in s.store.orderedWindows.flatMap { w in w.tabs.map { Item(socketPath: s.socketPath, tab: $0) } } }
    }

    /// The tabs matching `query`, best first, at most `limit`. An empty query
    /// matches nothing: the panel shows nothing until something is typed.
    public static func find(_ query: String, in items: [Item], limit: Int = 50) -> [Item] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let whole = words.joined(separator: " ")
        var scored: [(score: Int, at: Int, item: Item)] = []
        for (i, item) in items.enumerated() {
            let title = item.tab.title.lowercased()
            let address = shown(item.tab.url).lowercased()
            guard words.allSatisfy({ title.contains($0) || address.contains($0) }) else { continue }
            let score: Int
            if title.hasPrefix(whole) || address.hasPrefix(whole) { score = 0 }
            else if startsAWord(whole, in: title) || startsAWord(whole, in: address) { score = 1 }
            else { score = 2 }
            scored.append((score, i, item))
        }
        return scored.sorted { ($0.score, $0.at) < ($1.score, $1.at) }.prefix(limit).map(\.item)
    }

    /// An address as a person reads it: no scheme, no "www.".
    public static func shown(_ url: String) -> String {
        var s = Substring(url)
        if let r = s.range(of: "://") { s = s[r.upperBound...] }
        if s.lowercased().hasPrefix("www.") { s = s.dropFirst(4) }
        return String(s)
    }

    private static func startsAWord(_ text: String, in haystack: String) -> Bool {
        var from = haystack.startIndex
        while let r = haystack.range(of: text, range: from..<haystack.endIndex) {
            if r.lowerBound == haystack.startIndex { return true }
            let before = haystack[haystack.index(before: r.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            from = haystack.index(after: r.lowerBound)
        }
        return false
    }
}
