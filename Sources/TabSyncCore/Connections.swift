import Foundation

/// What the Sidebar page and `betterlink tabs helpers` say about one browser's
/// Tabs extension: which of its profiles are connected, and on what version.
/// The helper file (`HostRegistration`) only says the browser *can* start the
/// helper; this says whether an extension really did.
public struct ExtensionConnections: Equatable, Sendable {
    /// One connected copy of the extension, one per browser profile.
    public struct Profile: Equatable, Sendable {
        /// The profile's name in the browser ("Work"), or nil while not yet found.
        public var name: String?
        /// The extension version it runs, from its hello.
        public var version: String?
        /// It runs an older version than the folder holds. A copy that can
        /// reload itself is asked to at once (`TabsModel`), so this lasts
        /// only for one that can't (before 0.3) or that was loaded from
        /// another folder.
        public var needsReload: Bool

        public init(name: String?, version: String?, needsReload: Bool) {
            self.name = name; self.version = version; self.needsReload = needsReload
        }
    }

    public enum State: String, Sendable {
        /// The browser isn't open, so nothing can be connected.
        case notRunning
        /// Open, but no copy of the extension has said hello.
        case none
        /// Every connected copy runs the folder's version (or can't be compared).
        case connected
        /// At least one connected copy needs reloading by hand.
        case outdated
    }

    public var state: State
    /// Connected profiles, sorted by name.
    public var profiles: [Profile]

    /// `sessions` are this browser's connected copies; `folderVersion` is the
    /// version in the folder browsers load the extension from.
    public init(running: Bool, sessions: [(name: String?, version: String?)], folderVersion: String?) {
        profiles = sessions.map { s in
            let older = s.version.flatMap { v in folderVersion.map { ExtensionCopy.compare(v, $0) == .orderedAscending } } ?? false
            return Profile(name: s.name, version: s.version, needsReload: older)
        }
        .sorted { ($0.name ?? "\u{10FFFF}").localizedStandardCompare($1.name ?? "\u{10FFFF}") == .orderedAscending }
        if profiles.isEmpty { state = running ? .none : .notRunning }
        else { state = profiles.contains(where: \.needsReload) ? .outdated : .connected }
    }

    /// One line for under the browser's row, or nil when there's nothing to say.
    /// `helperSetUp`: the helper file is in place (without it no extension
    /// can connect, and the row's own badge says so).
    public func line(browser: String, helperSetUp: Bool) -> String? {
        switch state {
        case .notRunning:
            return nil
        case .none:
            guard helperSetUp else { return nil }
            return "No Tabs extension is connected in \(browser). Add it in each profile, and check that Developer mode is still on in chrome://extensions."
        case .connected, .outdated:
            let names = profiles.map(Self.label)
            var text = "Connected: " + names.joined(separator: ", ") + "."
            let stale = profiles.filter(\.needsReload).map(Self.label)
            if !stale.isEmpty {
                text += " " + stale.joined(separator: ", ") + (stale.count == 1 ? " runs" : " run")
                    + " an older Tabs extension than betterlink's: reload it in chrome://extensions, or load the folder Show in Finder opens."
            }
            return text
        }
    }

    static func label(_ p: Profile) -> String {
        (p.name ?? "a profile") + (p.version.map { " (\($0))" } ?? "")
    }
}

/// When to check a browser's tab list against the browser (`Command.refresh`):
/// as it comes to the front, at most once a minute per connection, never in
/// the first minute after it connected (its snapshot is that fresh). A list
/// that went wrong without a sequence gap is put right the next time you
/// switch to the browser, for the cost of one list without icons.
public struct RefreshPacer: Sendable {
    public static let interval: TimeInterval = 60

    private var last: [String: TimeInterval] = [:]

    public init() {}

    /// A connection appeared: its first snapshot counts as a check.
    public mutating func connected(_ id: String, now: TimeInterval) {
        if last[id] == nil { last[id] = now }
    }

    /// Its browser came to the front: whether to check it now.
    public mutating func browserInFront(_ id: String, now: TimeInterval) -> Bool {
        if let at = last[id], now - at < Self.interval { return false }
        last[id] = now
        return true
    }

    /// Forgets connections that are gone.
    public mutating func keep(_ ids: Set<String>) {
        last = last.filter { ids.contains($0.key) }
    }
}
