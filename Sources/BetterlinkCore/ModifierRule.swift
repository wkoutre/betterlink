import Foundation

/// The modifier keys held down when a link was clicked. Caps Lock and fn are
/// never part of it, so they can't stop a rule from matching.
///
/// Stored and shown to agents as names ("control", "option", "shift",
/// "command"), and to people as symbols in Apple's order: ⌃⌥⇧⌘.
public struct ModifierKeys: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ModifierKeys(rawValue: 1 << 0)
    public static let option = ModifierKeys(rawValue: 1 << 1)
    public static let shift = ModifierKeys(rawValue: 1 << 2)
    public static let command = ModifierKeys(rawValue: 1 << 3)

    /// Every key, in the order macOS menus show them.
    public static let ordered: [(key: ModifierKeys, name: String, symbol: String, label: String)] = [
        (.control, "control", "⌃", "Control"),
        (.option, "option", "⌥", "Option"),
        (.shift, "shift", "⇧", "Shift"),
        (.command, "command", "⌘", "Command"),
    ]

    /// "⌃⌘", or "" when no key is held.
    public var symbols: String { Self.ordered.filter { contains($0.key) }.map(\.symbol).joined() }

    /// ["control", "command"].
    public var names: [String] { Self.ordered.filter { contains($0.key) }.map(\.name) }

    /// "Control-Command", for VoiceOver and sentences.
    public var spoken: String { Self.ordered.filter { contains($0.key) }.map(\.label).joined(separator: "-") }

    /// Keys from their names; also accepts "ctrl", "alt", "opt" and "cmd".
    /// Nil when any name is unknown, so a typo is refused instead of
    /// quietly making a different combination.
    public init?(names: [String]) {
        var keys: ModifierKeys = []
        for raw in names {
            switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
            case "control", "ctrl", "⌃": keys.insert(.control)
            case "option", "opt", "alt", "⌥": keys.insert(.option)
            case "shift", "⇧": keys.insert(.shift)
            case "command", "cmd", "⌘": keys.insert(.command)
            default: return nil
            }
        }
        self = keys
    }
}

extension ModifierKeys: Codable {
    public init(from decoder: Decoder) throws {
        let names = try decoder.singleValueContainer().decode([String].self)
        guard let keys = ModifierKeys(names: names) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unknown modifier key in \(names)."))
        }
        self = keys
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(names)
    }
}

/// "Holding ⌃⌘ opens links in <profile>": one row of the Modifier Keys
/// editor. Checked before config.ts and the Link Rules, because holding the
/// keys is a choice made for this one click.
public struct ModifierRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var keys: ModifierKeys
    /// Bundle id of the browser.
    public var browser: String
    /// The profile within that browser (`BrowserProfile.directory`).
    public var profile: String
    public var target: ProfileRef { ProfileRef(browser: browser, directory: profile) }

    public init(id: UUID = UUID(), keys: ModifierKeys, browser: String = Browser.brave.bundleId, profile: String) {
        self.id = id; self.keys = keys; self.browser = browser; self.profile = profile
    }

    /// Why the rule can never match, or nil when it is usable.
    public var problem: String? {
        keys.isEmpty ? "Choose at least one key." : nil
    }

    /// Exactly these keys, no more and no fewer: ⌃⌘ doesn't match ⌃⌥⌘, so
    /// each combination can have its own profile, and a plain ⌘-click (how
    /// Terminal opens links) never matches a ⌃⌘ rule.
    public func matches(_ held: ModifierKeys) -> Bool {
        problem == nil && held == keys
    }

    /// Problems with a whole list: each rule's own, and two rules with the
    /// same keys (only the first could ever match). Indexed like the list.
    public static func problems(in rules: [ModifierRule]) -> [Int: String] {
        var out: [Int: String] = [:]
        for (i, r) in rules.enumerated() {
            if let p = r.problem { out[i] = p; continue }
            if let j = rules[..<i].firstIndex(where: { $0.keys == r.keys }) {
                out[i] = "\(r.keys.symbols) is already used by rule \(j + 1)."
            }
        }
        return out
    }
}
