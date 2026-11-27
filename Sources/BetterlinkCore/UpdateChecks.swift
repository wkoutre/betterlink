import Foundation

/// Whether betterlink checks for updates by itself (once an hour, a plain
/// request for the release feed on GitHub; nothing about the user is sent),
/// and whether it installs what it finds without asking. Stored where Sparkle
/// reads them, under Sparkle's own keys, so the window, the CLI and the
/// updater agree. Per Mac, like MenuBarIcon.
public enum UpdateChecks {
    public static let defaultsKey = "SUEnableAutomaticChecks"
    public static let installKey = "SUAutomaticallyUpdate"

    /// How often Sparkle looks, in seconds (SUScheduledCheckInterval). An hour
    /// is the shortest Sparkle allows. Releases ship several times a day, so a
    /// daily look left a Mac up to a day behind.
    public static let checkInterval: TimeInterval = 3600

    /// How long nobody has to touch the keyboard, mouse or trackpad before a
    /// downloaded update installs and betterlink restarts. Restarting takes a
    /// second, but the sidebar disappears and comes back while it does, so it
    /// waits for a moment nobody is looking.
    public static let idleBeforeInstall: TimeInterval = 120

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

    /// On unless turned off (Info.plist also turns it on): updates download in
    /// the background and install by themselves.
    public static func installsAutomatically(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: installKey) as? Bool ?? true
    }

    public static func setInstallsAutomatically(_ on: Bool, in defaults: UserDefaults) {
        defaults.set(on, forKey: installKey)
    }

    /// Before automatic installs were on by default, Sparkle's own prompt had
    /// an "Automatically download and install updates" box, and answering the
    /// prompt with it clear stored "off" for a setting betterlink never showed.
    /// Turn it on once per Mac, so existing installs get updates by
    /// themselves too. Returns whether it changed anything. The General page
    /// switch (and the CLI) can turn it off again for good.
    public static let installMigrationKey = "BetterlinkAutoInstallDefaultApplied"

    @discardableResult
    public static func applyInstallDefault(in defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: installMigrationKey) else { return false }
        defaults.set(true, forKey: installMigrationKey)
        guard defaults.object(forKey: installKey) as? Bool == false else { return false }
        defaults.set(true, forKey: installKey)
        return true
    }

    /// Whether a downloaded update should install now: only once the person
    /// has left the Mac alone for `idleBeforeInstall`. Quitting betterlink, or
    /// logging out, installs it too (Sparkle does that by itself).
    public static func shouldInstallNow(idleSeconds: TimeInterval) -> Bool {
        idleSeconds.isFinite && idleSeconds >= idleBeforeInstall
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
