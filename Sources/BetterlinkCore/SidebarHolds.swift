import Foundation

/// A tab as the sidebar needs it to tell which saved link it belongs to.
public struct OpenTab: Equatable, Sendable {
    public var id: Int
    public var url: String

    public init(id: Int, url: String) { self.id = id; self.url = url }
}

/// Which open tab each saved link holds.
///
/// Like a pinned tab in Arc and Dia: a saved link you open keeps its tab while
/// you move around inside the site. The tab stays with its link instead of
/// dropping into the tab list, and the next click on the link switches back to
/// that tab instead of opening the site a second time. That also covers a
/// saved address that redirects (mail.google.com to its inbox), which an
/// address comparison alone never sees as open.
///
/// A tab that merely happens to be at a saved link's address is a weaker
/// match: it shows with the link only while it stays at that address.
public struct LinkHolds: Equatable, Sendable {
    /// Tab id -> the saved link holding it.
    public private(set) var links: [Int: UUID] = [:]

    public init() {}

    public var isEmpty: Bool { links.isEmpty }

    public func link(holding tab: Int) -> UUID? { links[tab] }

    /// The tabs a link holds (one per window it was opened in), lowest id first.
    public func tabs(heldBy link: UUID) -> [Int] {
        links.filter { $0.value == link }.map(\.key).sorted()
    }

    /// Makes `tab` this link's tab from now on, wherever it navigates.
    public mutating func hold(_ tab: Int, for link: UUID) { links[tab] = link }

    public mutating func release(tab: Int) { links[tab] = nil }

    /// Lets go of every tab a link holds (the link was removed): they go back
    /// to the tab list.
    public mutating func release(link: UUID) { links = links.filter { $0.value != link } }

    /// Forgets tabs that closed and links that no longer exist. True when
    /// anything changed.
    @discardableResult
    public mutating func prune(tabs: Set<Int>, links known: Set<UUID>) -> Bool {
        let kept = links.filter { tabs.contains($0.key) && known.contains($0.value) }
        guard kept.count != links.count else { return false }
        links = kept
        return true
    }

    // MARK: - Across a browser restart

    /// Where each held tab is now, by link. Tab ids don't survive a browser
    /// restart, but the restored tabs come back at these addresses.
    public func addresses(of tabs: [OpenTab]) -> [UUID: [String]] {
        var out: [UUID: [String]] = [:]
        for t in tabs { if let l = links[t.id] { out[l, default: []].append(t.url) } }
        return out
    }

    /// After a restart: holds, for each remembered address, the first tab at it
    /// that nothing holds yet. Links that no longer exist are skipped.
    public mutating func restore(_ remembered: [UUID: [String]], tabs: [OpenTab], links known: Set<UUID>) {
        var free: [String: [Int]] = [:]
        for t in tabs.reversed() where links[t.id] == nil && !t.url.isEmpty {
            free[SavedLink.key(t.url), default: []].append(t.id)
        }
        // A fixed order, so two links remembered at one address always split
        // its tabs the same way.
        for link in remembered.keys.sorted(by: { $0.uuidString < $1.uuidString }) where known.contains(link) {
            for url in remembered[link] ?? [] {
                if let tab = free[SavedLink.key(url)]?.popLast() { links[tab] = link }
            }
        }
    }
}

/// What one window's sidebar shows for its saved links: worked out once per
/// change, in one pass over the links and the tabs.
public struct LinkResolution: Equatable, Sendable {
    /// The tab each saved link stands for in this window.
    public private(set) var tabs: [UUID: Int] = [:]
    /// Links whose held tab is on another page than the saved one.
    public private(set) var away: Set<UUID> = []
    /// The tabs shown with their link instead of in the tab list.
    public private(set) var claimed: Set<Int> = []

    public init() {}

    /// - Parameters:
    ///   - links: the Sidebar Profile's saved links, Favorites first (`allLinks`).
    ///   - tabs: the window's tabs, in tab order.
    ///   - holds: the tabs links hold in this browser.
    ///
    /// A held tab goes to its link wherever it has navigated. Then each link
    /// without one takes the first free tab at its address; a second tab at
    /// the same address stays in the tab list.
    public init(links: [SavedLink], tabs open: [OpenTab], holds: LinkHolds = LinkHolds()) {
        guard !links.isEmpty, !open.isEmpty else { return }
        var keyOf: [UUID: String] = [:]
        keyOf.reserveCapacity(links.count)
        for l in links { keyOf[l.id] = SavedLink.key(l.url) }

        // Free tabs by address, last first so popLast() hands out the first.
        var free: [String: [Int]] = [:]
        for t in open.reversed() {
            if let l = holds.link(holding: t.id), keyOf[l] != nil { continue }
            if !t.url.isEmpty { free[SavedLink.key(t.url), default: []].append(t.id) }
        }
        for t in open {
            guard let l = holds.link(holding: t.id), let k = keyOf[l], tabs[l] == nil else { continue }
            tabs[l] = t.id
            claimed.insert(t.id)
            if SavedLink.key(t.url) != k { away.insert(l) }
        }
        for l in links where tabs[l.id] == nil {
            guard let k = keyOf[l.id], let t = free[k]?.popLast() else { continue }
            tabs[l.id] = t
            claimed.insert(t)
        }
    }

    public func tab(for link: UUID) -> Int? { tabs[link] }
    public func isAway(_ link: UUID) -> Bool { away.contains(link) }
}

/// Remembers each address's comparison key. Working one out parses the
/// address, and the sidebar asks for the same few hundred on every tab event.
enum PageKeys {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [String: String] = [:]
    /// Enough for every tab and saved link of a heavy session; past it the
    /// table starts over rather than growing without end.
    static let limit = 4096

    static func key(_ address: String, compute: (String) -> String) -> String {
        lock.lock()
        if let k = known[address] { lock.unlock(); return k }
        lock.unlock()
        let k = compute(address)
        lock.lock()
        if known.count >= limit { known.removeAll(keepingCapacity: true) }
        known[address] = k
        lock.unlock()
        return k
    }

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return known.count
    }
}
