import Foundation

/// What changed in each release, newest first: the Changelog page and
/// `betterlink changelog list`.
///
/// Nobody writes it. scripts/gen-changelog.py reads it from git history when
/// the app is built (each release tag, and the pull request titles merged
/// since the one before) into Contents/Resources/changelog.json, and the
/// release workflow publishes the same entry as the GitHub Release's notes.
public struct Changelog: Codable, Equatable, Sendable {
    public struct Change: Codable, Equatable, Sendable, Hashable {
        public let text: String
        /// The pull request behind it, when the commit names one.
        public let pr: Int?

        public init(text: String, pr: Int? = nil) { self.text = text; self.pr = pr }
    }

    public struct Release: Codable, Equatable, Sendable, Identifiable {
        public let version: String
        /// The day it shipped, YYYY-MM-DD in UTC.
        public let date: String
        public let changes: [Change]
        public var id: String { version }

        public init(version: String, date: String, changes: [Change]) {
            self.version = version; self.date = date; self.changes = changes
        }

        /// The date as a Date, for formatting; nil if it isn't YYYY-MM-DD.
        public var day: Date? {
            let parts = date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            return utc.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
        }
    }

    /// owner/name on GitHub, for links to pull requests.
    public let repository: String?
    /// Newest first.
    public let releases: [Release]
    /// Changes merged after the newest release tag. Only a local build of an
    /// untagged commit has any; a release is always built from its tag.
    public let unreleased: [Change]?

    public init(repository: String?, releases: [Release], unreleased: [Change]? = nil) {
        self.repository = repository; self.releases = releases; self.unreleased = unreleased
    }

    public static let fileName = "changelog.json"

    public static func load(from url: URL) -> Changelog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Changelog.self, from: data)
    }

    /// The changelog built into this copy of betterlink; nil when it was built
    /// without one (a source archive, or a clone with no history).
    public static func bundled(_ bundle: Bundle = .main) -> Changelog? {
        guard let url = bundle.url(forResource: "changelog", withExtension: "json") else { return nil }
        return load(from: url)
    }

    /// The pull request's page, when the change names one.
    public func link(for change: Change) -> URL? {
        guard let pr = change.pr, let repository, !repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)/pull/\(pr)")
    }

    /// The releases newer than `since` (all when nil), newest first, at most `limit`.
    public func releases(since: String? = nil, limit: Int? = nil) -> [Release] {
        var out = releases
        if let since, let floor = Self.parts(since) {
            out = out.filter { Self.parts($0.version).map { floor.lexicographicallyPrecedes($0) } ?? false }
        }
        if let limit { out = Array(out.prefix(max(0, limit))) }
        return out
    }

    /// "0.3.22" as [0, 3, 22]; nil if it isn't three whole numbers.
    public static func parts(_ version: String) -> [Int]? {
        let p = version.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard p.count == 3, p.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return p.compactMap { $0 }
    }
}

/// `betterlink changelog list`: the same releases the Changelog page shows.
public enum ChangelogAgent {
    public static let commands = ["changelog.list"]

    public struct Refusal: Error, Equatable {
        public let message: String
    }

    public static func run(_ command: String, input: [String: Any], changelog: Changelog?,
                           installed: String) -> Result<[String: Any], Refusal> {
        guard command == "changelog.list" else { return .failure(Refusal(message: "Unknown command \(command).")) }
        var since: String?
        if let v = input["since"], !(v is NSNull) {
            guard let s = v as? String, Changelog.parts(s) != nil else {
                return .failure(Refusal(message: "since must be a version such as 0.3.20."))
            }
            since = s
        }
        var limit: Int?
        if let v = input["limit"], !(v is NSNull) {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n),
                  let i = Int(exactly: n), i >= 1 else {
                return .failure(Refusal(message: "limit must be a whole number, 1 or more."))
            }
            limit = i
        }
        guard let changelog else {
            return .success(["installed": installed, "releases": [Any](),
                             "note": "This copy of betterlink was built without its release history."])
        }
        let releases = changelog.releases(since: since, limit: limit).map { r -> [String: Any] in
            ["version": r.version, "date": r.date,
             "changes": r.changes.map { c -> [String: Any] in
                 var out: [String: Any] = ["text": c.text]
                 if let pr = c.pr { out["pr"] = pr }
                 if let url = changelog.link(for: c) { out["link"] = url.absoluteString }
                 return out
             }]
        }
        return .success(["installed": installed, "releases": releases])
    }
}
