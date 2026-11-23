import Foundation

/// The Link Rules and the profile list, saved as JSON that only the user can
/// read. The profile list is stored because macOS doesn't let betterlink read
/// the browser's own list (another app's data); `betterlink --import-profiles`,
/// run from Terminal, copies it in.
public struct RuleStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public init(folder: SettingsFolder) { self.file = folder.rulesFile }

    public struct Contents: Codable, Equatable, Sendable {
        public var version = 1
        public var rules: [Rule]
        public var profiles: [BrowserProfile]?
        /// Where links no rule claims open. Before 0.2 this lived in the app's
        /// preferences; it is here so the CLI and a synced folder carry it.
        public var fallback: ProfileRef?
        /// Whether the Log page shows in the sidebar.
        public var showLog: Bool?
        /// "Holding ⌃⌘ opens links in Work". Absent in files written by 0.2.
        public var modifierRules: [ModifierRule]?
        public init(rules: [Rule] = [], profiles: [BrowserProfile]? = nil, fallback: ProfileRef? = nil, showLog: Bool? = nil,
                    modifierRules: [ModifierRule]? = nil) {
            self.rules = rules; self.profiles = profiles; self.fallback = fallback; self.showLog = showLog
            self.modifierRules = modifierRules
        }
    }

    /// The saved contents, or empty when there is no file. Throws when the
    /// file exists but is unsafe or unreadable, so a damaged file is reported
    /// instead of silently routing with no rules.
    public func load() throws -> Contents {
        guard FileManager.default.fileExists(atPath: file.path) else { return Contents() }
        if let problem = FileSafety.problem(with: file) { throw ConfigError.unsafeFile("Refused rules.json: \(problem).") }
        return try JSONDecoder().decode(Contents.self, from: Data(contentsOf: file))
    }

    /// Changes part of the file, starting from what is on disk now, so a
    /// change made elsewhere (such as --import-profiles) is never lost.
    /// Throws, writing nothing, when the file exists but does not load.
    /// The app and the CLI (an agent) can write at the same time, so the
    /// read-change-write holds an exclusive lock on a file beside rules.json.
    @discardableResult
    public func update(_ change: (inout Contents) throws -> Void) throws -> Contents {
        try withLock {
            var contents = try load()
            try change(&contents)
            try save(contents)
            return contents
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(dir.appendingPathComponent(".rules.lock").path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw ConfigError.unsafeFile("Couldn't lock rules.json (\(String(cString: strerror(errno)))).") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw ConfigError.unsafeFile("Couldn't lock rules.json (\(String(cString: strerror(errno)))).") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    public func save(_ contents: Contents) throws {
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // When rules.json is a symlink (into a dotfiles repo, say), write the
        // file it points to: an atomic write to the link itself would replace
        // the link with a plain file and leave its target stale.
        let target = file.resolvingSymlinksInPath()
        try enc.encode(contents).write(to: target, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
}

/// betterlink's log. Kept in memory only: it is gone when betterlink quits,
/// and nothing about the links you open is written to disk or to the system
/// log.
public struct LogBuffer: Sendable {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let date: Date
        /// The link as betterlink received it; nil for config messages.
        public let link: String?
        public let opener: String?
        public let profileName: String?
        public let message: String
    }

    public let capacity: Int
    public private(set) var entries: [Entry] = []

    public init(capacity: Int = 200) { self.capacity = capacity }

    public mutating func append(link: String?, opener: String?, profileName: String?, message: String, date: Date = Date()) {
        entries.append(Entry(id: UUID(), date: date, link: link, opener: opener, profileName: profileName, message: message))
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// The most recent routed links, newest first.
    public func recentLinks(_ n: Int = 20) -> [Entry] {
        Array(entries.reversed().filter { $0.link != nil }.prefix(n))
    }

    public mutating func clear() { entries.removeAll() }
}
