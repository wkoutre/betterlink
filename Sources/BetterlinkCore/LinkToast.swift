import Foundation

/// The small toast betterlink shows when a rule (held keys, config.ts or a
/// Link Rule) chooses where a link opens. Links that fall through to the
/// fallback show nothing. On unless turned off.
///
/// Kept per Mac in UserDefaults, like the menu bar icon: where a toast sits
/// suits one screen, not every Mac sharing a settings folder.
public enum LinkToast {
    public enum Position: String, CaseIterable, Sendable {
        case top, bottom
        public var label: String { self == .top ? "Top of the screen" : "Bottom of the screen" }
    }

    public static let shownKey = "showLinkToast"
    public static let positionKey = "linkToastPosition"
    /// How long a toast stays on screen.
    public static let duration: TimeInterval = 1.6

    /// Shown unless it was turned off.
    public static func isShown(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: shownKey) as? Bool ?? true
    }

    public static func setShown(_ shown: Bool, in defaults: UserDefaults) {
        defaults.set(shown, forKey: shownKey)
    }

    /// Top unless set to bottom (an unknown stored value counts as top).
    public static func position(in defaults: UserDefaults) -> Position {
        defaults.string(forKey: positionKey).flatMap(Position.init(rawValue:)) ?? .top
    }

    public static func setPosition(_ position: Position, in defaults: UserDefaults) {
        defaults.set(position.rawValue, forKey: positionKey)
    }

    /// What the toast says, or nil when no rule chose the profile (the
    /// fallback, a refused link, an error on the way).
    public static func message(for decision: Decision) -> (profile: BrowserProfile, detail: String)? {
        guard case .open(let p, _) = decision.action, let by = decision.chosenBy else { return nil }
        return (p, by.label)
    }
}
