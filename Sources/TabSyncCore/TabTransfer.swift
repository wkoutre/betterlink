import Foundation

/// Sending a tab to another browser profile or browser: the page opens there,
/// and only once that browser says it opened does the tab close here. A send
/// whose open fails or never answers leaves the tab where it was, so a page is
/// never lost on the way.
public struct TabTransfer: Equatable, Sendable {
    /// The tab to close once the open answers yes.
    public struct Source: Equatable, Sendable {
        public var socketPath: String
        public var tabId: Int
        public init(socketPath: String, tabId: Int) { self.socketPath = socketPath; self.tabId = tabId }
    }

    /// Open commands waiting for their answer, by command id.
    public private(set) var pending: [String: Source] = [:]

    public init() {}

    /// Whether a page at `url` can be sent: only web pages and files. Another
    /// browser has its own settings and internal pages (chrome://, brave://),
    /// and a blank tab has nothing to send.
    public static func canSend(_ url: String) -> Bool {
        let lower = url.lowercased()
        return (lower.hasPrefix("https://") || lower.hasPrefix("http://") || lower.hasPrefix("file://"))
            && !url.unicodeScalars.contains { $0.value < 0x20 }
    }

    /// Whether a tab may go from `source` to `target`: another session, and
    /// never out of a private window (that would carry a private page into a
    /// profile that keeps history).
    public static func canSend(from source: String, to target: String, incognito: Bool) -> Bool {
        source != target && !incognito
    }

    /// What each connected session is called: `base` ("Work (Google Chrome)",
    /// or the browser alone while its profile can't be read). Sessions whose
    /// base reads the same are numbered in socket path order ("Google Chrome 1",
    /// "Google Chrome 2"), so the sidebar's menu and `tabs send --to` can always
    /// tell them apart, and both number them the same way.
    public static func labels(_ sessions: [(id: String, base: String)]) -> [String: String] {
        var out: [String: String] = [:]
        for (base, group) in Dictionary(grouping: sessions, by: \.base) {
            guard group.count > 1 else { out[group[0].id] = base; continue }
            for (i, s) in group.sorted(by: { $0.id < $1.id }).enumerated() { out[s.id] = "\(base) \(i + 1)" }
        }
        return out
    }

    /// The open command `command` will, once it answers yes, close `source`.
    public mutating func started(command: String, closing source: Source) { pending[command] = source }

    /// The answer to `command`: the tab to close now, or nil (not a send, or
    /// the open failed and the tab stays).
    public mutating func answered(command: String, ok: Bool) -> Source? {
        guard let source = pending.removeValue(forKey: command) else { return nil }
        return ok ? source : nil
    }

    /// Forgets a send that never answered: its tab stays where it was.
    public mutating func gaveUp(command: String) { pending[command] = nil }
}
