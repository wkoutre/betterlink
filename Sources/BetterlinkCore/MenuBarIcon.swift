import Foundation

/// Whether betterlink shows its icon in the menu bar. Kept per Mac in
/// UserDefaults, not in rules.json: a settings folder synced between Macs
/// shouldn't hide the icon on all of them at once.
///
/// With the icon hidden, the window still opens when betterlink is opened by
/// hand (Spotlight, Finder, Launchpad), so there is always a way back in.
public enum MenuBarIcon {
    public static let defaultsKey = "showMenuBarIcon"
    /// Where the setting lives while `BETTERLINK_HOME` is set, so tests and
    /// development never change the real one.
    public static let developmentSuite = "com.wkoutre.betterlink.development"

    public static func defaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        if let home = environment["BETTERLINK_HOME"], !home.isEmpty, let d = UserDefaults(suiteName: developmentSuite) { return d }
        return .standard
    }

    /// Shown unless it was turned off.
    public static func isShown(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    public static func setShown(_ shown: Bool, in defaults: UserDefaults) {
        defaults.set(shown, forKey: defaultsKey)
    }
}
