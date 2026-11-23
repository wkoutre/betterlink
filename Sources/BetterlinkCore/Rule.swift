import Foundation

/// One row of the Link Rules editor: "Open <kind> <pattern> in <profile>".
public struct Rule: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case contains     // "URLs containing"
        case startsWith   // "URLs starting with"
        case domain       // "domains matching"
    }

    public var id: UUID
    public var kind: Kind
    public var pattern: String
    /// Bundle id of the browser the rule opens links in.
    public var browser: String
    /// The profile within that browser (`BrowserProfile.directory`).
    public var profile: String
    public var target: ProfileRef { ProfileRef(browser: browser, directory: profile) }

    public init(id: UUID = UUID(), kind: Kind, pattern: String, browser: String = Browser.brave.bundleId, profile: String) {
        self.id = id; self.kind = kind; self.pattern = pattern; self.browser = browser; self.profile = profile
    }

    private enum CodingKeys: String, CodingKey { case id, kind, pattern, browser, profile }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        pattern = try c.decode(String.self, forKey: .pattern)
        // Before 0.2 betterlink only knew Brave, so a rule without a browser is Brave's.
        browser = try c.decodeIfPresent(String.self, forKey: .browser) ?? Browser.brave.bundleId
        profile = try c.decode(String.self, forKey: .profile)
    }


    /// Why the pattern can never match, or nil when it is usable.
    public var problem: String? {
        switch kind {
        case .contains:
            return pattern.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter some text to look for." : nil
        case .domain:
            return Self.domain(from: pattern) == nil ? "Enter a domain such as acme.com." : nil
        case .startsWith:
            return Self.prefixLink(from: pattern) == nil ? "Enter the start of a link, such as https://app.acme.com/swap." : nil
        }
    }

    public func matches(_ link: Link) -> Bool {
        switch kind {
        case .contains:
            // The link as handed to the browser, or as people read it: a
            // pattern such as "café" or "tab[]=" matches whether the link
            // spells it out or percent-encodes it.
            let needle = pattern.trimmingCharacters(in: .whitespaces).lowercased()
            guard !needle.isEmpty else { return false }
            let href = link.href.lowercased()
            return href.contains(needle) || (href.removingPercentEncoding?.contains(needle) ?? false)
        case .domain:
            // acme.com matches acme.com and any subdomain, never
            // evil-acme.com or acme.com.evil.com.
            guard let d = Self.domain(from: pattern) else { return false }
            return link.host == d || link.host.hasSuffix("." + d)
        case .startsWith:
            // The host must be equal, so app.acme.com.evil.com never
            // matches a rule for https://app.acme.com.
            guard let p = Self.prefixLink(from: pattern) else { return false }
            if let scheme = p.scheme, scheme != link.scheme { return false }
            guard p.link.host == link.host, p.link.port == link.port else { return false }
            let rest = link.path + (link.query.map { "?" + $0 } ?? "")
            let want = p.link.path + (p.link.query.map { "?" + $0 } ?? "")
            // In the path, the prefix must end at a boundary: .../billing
            // matches /billing, /billing/x, /billing?x and /billing#x, not
            // /billingx. A prefix that reaches into the query, or ends in
            // "/", is a plain prefix.
            guard rest.hasPrefix(want) else { return false }
            if rest.count == want.count || want.hasSuffix("/") || p.link.query != nil { return true }
            let next = rest[rest.index(rest.startIndex, offsetBy: want.count)]
            return next == "/" || next == "?" || next == "#"
        }
    }

    /// "acme.com", "*.acme.com", "https://acme.com/x" -> "acme.com".
    static func domain(from pattern: String) -> String? {
        var p = pattern.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("*.") { p.removeFirst(2) } else if p.hasPrefix(".") { p.removeFirst() }
        guard !p.isEmpty else { return nil }
        if !p.contains("://") { p = "https://" + p }
        guard case .web(let link) = LinkParser.parse(p), !link.host.hasPrefix("[") else { return nil }
        return link.host
    }

    /// The parsed prefix. `scheme` is nil when the pattern did not name one,
    /// so "app.acme.com/swap" matches both http and https.
    static func prefixLink(from pattern: String) -> (scheme: String?, link: Link)? {
        let p = pattern.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return nil }
        let lower = p.lowercased()
        let named = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        guard case .web(let link) = LinkParser.parse(named ? p : "https://" + p) else { return nil }
        return (named ? link.scheme : nil, link)
    }
}
