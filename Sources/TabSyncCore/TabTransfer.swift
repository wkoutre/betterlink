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
