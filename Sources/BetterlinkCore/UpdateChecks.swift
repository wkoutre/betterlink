import Foundation

/// Whether betterlink checks for updates by itself (once a day, a plain
/// request for the release feed on GitHub; nothing about the user is sent).
/// Stored where Sparkle reads it, under Sparkle's own key, so the window, the
/// CLI and the updater agree. Per Mac, like MenuBarIcon.
public enum UpdateChecks {
    public static let defaultsKey = "SUEnableAutomaticChecks"

    /// The same separate domain as MenuBarIcon while `BETTERLINK_HOME` is set.
    public static func defaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        MenuBarIcon.defaults(environment: environment)
    }

    /// On unless turned off (Info.plist also turns it on).
    public static func isAutomatic(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    public static func setAutomatic(_ on: Bool, in defaults: UserDefaults) {
        defaults.set(on, forKey: defaultsKey)
    }

    /// The updater runs only in a build that carries an update key and feed,
    /// and never under `BETTERLINK_HOME` (tests and development stay offline).
    public static func updaterCanRun(info: [String: Any], environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let home = environment["BETTERLINK_HOME"], !home.isEmpty { return false }
        guard let key = info["SUPublicEDKey"] as? String, let data = Data(base64Encoded: key), data.count == 32 else { return false }
        guard let feed = info["SUFeedURL"] as? String, let url = URL(string: feed), url.scheme == "https" else { return false }
        return true
    }
}
