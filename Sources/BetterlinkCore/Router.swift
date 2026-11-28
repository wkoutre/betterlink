import Foundation

/// What config.ts said about a link.
public enum ScriptVerdict: Equatable, Sendable {
    /// Open in the profile with this name, optionally within one browser
    /// (named as betterlink shows it, or by bundle id).
    case profile(String, browser: String? = nil)
    /// Open in the first of these this Mac has: a list config.ts returned
    /// so one config.ts works on Macs with different browsers.
    case firstOf([ScriptTarget])
    /// The script returned nothing: carry on to the editor rules.
    case noOpinion
    /// The script threw, ran too long, or returned something invalid.
    case error(String)
}

/// One entry of a list config.ts returned: a profile name, optionally
/// within one browser.
public struct ScriptTarget: Equatable, Sendable {
    public var name: String
    public var browser: String?
    public init(_ name: String, browser: String? = nil) { self.name = name; self.browser = browser }
}

/// The part of config.ts the router needs. Implemented by `ConfigScript`.
public protocol LinkScript: Sendable {
    func route(_ link: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict
}

extension LinkScript {
    /// A link clicked with no modifier keys held.
    public func route(_ link: Link, opener: String?) -> ScriptVerdict { route(link, opener: opener, modifiers: []) }
}

public struct Decision: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Open `argument` in this profile.
        case open(profile: BrowserProfile, argument: String)
        /// Open nothing.
        case refuse
    }
    public let action: Action
    /// One line for the log and the link tester: why this happened.
    public let reason: String
    /// What chose the profile; nil when the fallback (or nothing) did.
    public let chosenBy: Chooser?

    public enum Chooser: Equatable, Sendable {
        case keys(ModifierKeys)
        case script
        /// A Link Rule, counted from 1.
        case rule(Int)

        /// "Holding ⌃⌘", "config.ts", "Rule 2".
        public var label: String {
            switch self {
            case .keys(let k): "Holding \(k.symbols)"
            case .script: "config.ts"
            case .rule(let n): "Rule \(n)"
            }
        }
    }

    public init(action: Action, reason: String, chosenBy: Chooser? = nil) {
        self.action = action; self.reason = reason; self.chosenBy = chosenBy
    }
}

/// Decides where a link opens. Pure: no I/O, so every path is unit-tested.
///
/// Order: the modifier keys held when the link was clicked, then config.ts,
/// then the editor rules top to bottom, then the fallback profile. Anything
/// betterlink cannot read with certainty, and any error on the way, goes to
/// the fallback profile, never to a Link Rule's profile. Only held keys,
/// which don't depend on the host, can choose another profile for it.
public struct Router: Sendable {
    public var rules: [Rule]
    /// "Holding ⌃⌘ opens links in Work". Checked first: holding the keys is
    /// a choice made for this one click.
    public var modifierRules: [ModifierRule]
    public var script: (any LinkScript)?
    public var catalog: ProfileCatalog
    /// The profile for links no rule claims.
    public var fallback: ProfileRef
    /// Bundle ids of the browsers installed on this Mac. A rule's profile in
    /// a browser that isn't installed is passed over for its next one, even
    /// when the catalog still lists it. nil: every browser in the catalog.
    public var installed: Set<String>?

    public init(rules: [Rule], modifierRules: [ModifierRule] = [], script: (any LinkScript)?,
                catalog: ProfileCatalog, fallback: ProfileRef, installed: Set<String>? = nil) {
        self.rules = rules; self.modifierRules = modifierRules; self.script = script
        self.catalog = catalog; self.fallback = fallback; self.installed = installed
    }

    /// Whether this Mac has the profile: the catalog lists it and its browser is installed.
    public func has(_ ref: ProfileRef) -> Bool {
        catalog.profile(ref) != nil && (installed?.contains(ref.browser) ?? true)
    }

    var fallbackProfile: BrowserProfile {
        catalog.profile(fallback) ?? BrowserProfile(browser: fallback.browser, directory: fallback.directory,
                                                    name: fallback.directory.isEmpty ? fallback.browser : fallback.directory, color: nil)
    }

    /// - Parameter modifiers: the modifier keys held when the link was
    ///   clicked (read as the link arrives; [] when none, or unknown).
    public func decide(_ raw: String, opener: String? = nil, modifiers: ModifierKeys = []) -> Decision {
        let fb = fallbackProfile
        let parsed = LinkParser.parse(raw)
        // Held keys choose the profile for anything that opens at all. They
        // don't depend on the host, so a host betterlink can't read with
        // certainty can't fool them; refused links stay refused.
        if let argument = Self.openable(parsed), let d = decideByKeys(modifiers, argument: argument, fallback: fb) {
            return d
        }
        switch parsed {
        case .refused(let why):
            return Decision(action: .refuse, reason: "Not opened: \(why).")
        case .file(let s):
            return Decision(action: .open(profile: fb, argument: s), reason: "Local file: opens in \(fb.name).")
        case .unroutable(let s, let why):
            // Only open what the browser will read as an http(s) link.
            let lower = s.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
                return Decision(action: .refuse, reason: "Not opened: \(why), and it is not a plain http(s) link.")
            }
            return Decision(action: .open(profile: fb, argument: s), reason: "Unclear host (\(why)): opens in \(fb.name).")
        case .web(let link):
            return decide(link, opener: opener, modifiers: modifiers, fallback: fb)
        }
    }

    /// The argument the browser would get, or nil when the input is never
    /// opened (refused, or an unclear host that isn't plain http(s)).
    static func openable(_ parsed: ParsedInput) -> String? {
        switch parsed {
        case .refused: return nil
        case .file(let s): return s
        case .web(let link): return link.href
        case .unroutable(let s, _):
            let lower = s.lowercased()
            return lower.hasPrefix("http://") || lower.hasPrefix("https://") ? s : nil
        }
    }

    /// The first modifier rule for exactly these keys, or nil when none.
    private func decideByKeys(_ held: ModifierKeys, argument: String, fallback fb: BrowserProfile) -> Decision? {
        guard !held.isEmpty, let rule = modifierRules.first(where: { $0.matches(held) }) else { return nil }
        guard let p = catalog.profile(rule.target) else {
            return Decision(action: .open(profile: fb, argument: argument),
                            reason: "Holding \(held.symbols) names a missing profile: opens in \(fb.name).")
        }
        return Decision(action: .open(profile: p, argument: argument), reason: "Holding \(held.symbols) chose \(p.name).",
                        chosenBy: .keys(held))
    }

    /// Where to rename one of two same-named profiles. With browser data
    /// access, names come from the browser, so a rename there reaches
    /// betterlink; without it, only a rename in betterlink does.
    static let renameHint = "rename one in the browser, or under Profiles › Edit Profiles… if betterlink can't read that browser's data"

    private func decide(_ link: Link, opener: String?, modifiers: ModifierKeys, fallback fb: BrowserProfile) -> Decision {
        if let script {
            switch script.route(link, opener: opener, modifiers: modifiers) {
            case .firstOf(let list):
                if let p = list.lazy.compactMap({ self.catalog.profile(named: $0.name, browser: $0.browser) })
                    .first(where: { self.installed?.contains($0.browser) ?? true }) {
                    return Decision(action: .open(profile: p, argument: link.href),
                                    reason: "config.ts chose \(p.name), the first of its profiles this Mac has.", chosenBy: .script)
                }
                let names = list.map { t in t.browser.map { "\($0) \(t.name)" } ?? t.name }.joined(separator: ", ")
                return Decision(action: .open(profile: fb, argument: link.href),
                                reason: "config.ts chose profiles this Mac doesn't have (\(names.isEmpty ? "an empty list" : names)): opens in \(fb.name).")
            case .profile(let name, let browser):
                if let p = catalog.profile(named: name, browser: browser) {
                    return Decision(action: .open(profile: p, argument: link.href), reason: "config.ts chose \(p.name).",
                                    chosenBy: .script)
                }
                let why: String
                let owner = catalog.profiles.first { $0.name == name }.map { Browser.known(bundleId: $0.browser)?.name ?? $0.browser }
                if let browser, catalog.isRepeated(name, in: browser) {
                    why = "\"\(name)\", but two \(browser) profiles have that name (\(Self.renameHint))"
                } else if browser == nil && catalog.ambiguousNames.contains(name) {
                    why = "a profile name more than one browser uses (return { browser, profile })"
                } else if browser == nil, catalog.repeatedNames.contains(name), let owner {
                    why = "\"\(name)\", but two \(owner) profiles have that name (\(Self.renameHint))"
                } else {
                    why = "unknown profile \"\(name)\""
                }
                return Decision(action: .open(profile: fb, argument: link.href),
                                reason: "config.ts chose \(why): opens in \(fb.name).")
            case .error(let msg):
                return Decision(action: .open(profile: fb, argument: link.href),
                                reason: "config.ts failed (\(msg)): opens in \(fb.name).")
            case .noOpinion:
                break
            }
        }
        for (i, rule) in rules.enumerated() where rule.problem == nil && rule.matches(link) {
            guard let ref = rule.opensIn(has), let p = catalog.profile(ref) else {
                let what = rule.backups.isEmpty ? "names a missing profile" : "names no profile this Mac has"
                return Decision(action: .open(profile: fb, argument: link.href),
                                reason: "Rule \(i + 1) \(what): opens in \(fb.name).")
            }
            let which = ref == rule.target ? "" : ", the first of its profiles this Mac has"
            return Decision(action: .open(profile: p, argument: link.href),
                            reason: "Rule \(i + 1) (\(rule.kind.label) \(rule.pattern)) chose \(p.name)\(which).",
                            chosenBy: .rule(i + 1))
        }
        return Decision(action: .open(profile: fb, argument: link.href), reason: "No rule matched: opens in \(fb.name).")
    }
}

extension Rule.Kind {
    public var label: String {
        switch self {
        case .contains: "URLs containing"
        case .startsWith: "URLs starting with"
        case .domain: "domains matching"
        }
    }
}
