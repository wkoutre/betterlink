import Foundation

/// Link Rules seen one profile at a time. The rules stay one list, checked
/// top to bottom, so grouping them by profile hides the order between
/// profiles. That order only changes where a link opens when two rules for
/// different profiles can match the same link; `crossings` finds those, so
/// the page can show them on the rules they affect.
///
/// A rule with backup profiles belongs to the profile it opens links in on
/// this Mac (`key`): the first of its profiles this Mac has, so the same
/// synced rule is under Dia Primary on one Mac and Brave Primary on another.
/// The default key is the rule's first choice.
/// A name for one profile's group of Link Rules, such as "Uniswap" for
/// Brave Profile 1. It labels that profile wherever betterlink shows it.
public struct GroupName: Codable, Equatable, Sendable {
    public var browser: String
    public var profile: String
    public var name: String
    public var target: ProfileRef { ProfileRef(browser: browser, directory: profile) }
    public init(browser: String, profile: String, name: String) { self.browser = browser; self.profile = profile; self.name = name }
}

public enum RuleGroups {
    public typealias Key = (Rule) -> ProfileRef

    /// The key the app and the CLI use: the first profile `has` accepts, else the first choice.
    public static func opensIn(_ has: @escaping (ProfileRef) -> Bool) -> Key { { $0.opensIn(has) ?? $0.target } }

    /// One profile's rules: where they sit in the full list (0-based).
    public struct Group: Equatable, Sendable {
        public let target: ProfileRef
        public let positions: [Int]
        public init(target: ProfileRef, positions: [Int]) { self.target = target; self.positions = positions }
    }

    /// The profiles that have rules, in `order` (the Profiles page order),
    /// then any profile `order` doesn't know, in the order its first rule
    /// appears.
    public static func groups(_ rules: [Rule], order: [ProfileRef] = [], key: Key = { $0.target }) -> [Group] {
        var positions: [ProfileRef: [Int]] = [:]
        var seen: [ProfileRef] = []
        for (i, r) in rules.enumerated() {
            let k = key(r)
            if positions[k] == nil { seen.append(k) }
            positions[k, default: []].append(i)
        }
        let known = order.filter { positions[$0] != nil }
        let rest = seen.filter { !known.contains($0) }
        return (known + rest).map { Group(target: $0, positions: positions[$0]!) }
    }

    /// The full list after one profile's rules were edited on their own:
    /// the edited rules take that profile's places in the order they now
    /// have, so every other profile's rule keeps its place. Rules beyond
    /// the places the profile had (new ones) go at the end, removed ones
    /// leave their place.
    public static func splice(_ all: [Rule], profile: ProfileRef, edited: [Rule], key: Key = { $0.target }) -> [Rule] {
        var queue = edited[...]
        var out: [Rule] = []
        for r in all {
            if key(r) == profile {
                if let next = queue.popFirst() { out.append(next) }
            } else {
                out.append(r)
            }
        }
        out.append(contentsOf: queue)
        return out
    }

    /// Two rules for different profiles that can match the same link, so
    /// their order decides where it opens. `earlier` is checked first.
    public struct Crossing: Hashable, Sendable {
        /// Positions in the full list (0-based), earlier < later.
        public let earlier: Int
        public let later: Int
        /// The earlier rule takes the link the later rule is written for
        /// (such as "domains matching acme.com" above "domains matching
        /// app.acme.com"), so the later rule never gets it. Otherwise the
        /// earlier rule is an exception carved out of the later one, which
        /// holds only while it stays above.
        public let hidesLater: Bool
        /// A link both rules match.
        public let example: String
    }

    /// Every pair of usable rules, for different profiles, that can match
    /// one link. Each rule is tried on the plainest link it is written for
    /// ("domains matching acme.com" on https://acme.com/), so the check is
    /// exact for domains and link starts; a "URLs containing" rule is
    /// checked against the others' links but has no link of its own.
    public static func crossings(_ rules: [Rule], key: Key = { $0.target }) -> [Crossing] {
        let samples = rules.map(sample)
        let keys = rules.map(key)
        var out: [Crossing] = []
        for j in rules.indices where rules[j].problem == nil {
            for i in 0..<j where rules[i].problem == nil && keys[i] != keys[j] {
                if let s = samples[j], rules[i].matches(s) {
                    out.append(Crossing(earlier: i, later: j, hidesLater: true, example: s.href))
                } else if let s = samples[i], rules[j].matches(s) {
                    out.append(Crossing(earlier: i, later: j, hidesLater: false, example: s.href))
                }
            }
        }
        return out
    }

    /// The plainest link a rule is written for, or nil for "URLs containing".
    static func sample(_ rule: Rule) -> Link? {
        guard rule.problem == nil else { return nil }
        switch rule.kind {
        case .contains: return nil
        case .domain:
            guard let d = Rule.domain(from: rule.pattern), case .web(let l) = LinkParser.parse("https://\(d)/") else { return nil }
            return l
        case .startsWith:
            return Rule.prefixLink(from: rule.pattern)?.link
        }
    }
}
