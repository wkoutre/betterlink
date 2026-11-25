import CryptoKit
import Foundation

/// Whether betterlink shows its icon in the menu bar. Kept per Mac in
/// UserDefaults, not in rules.json: a settings folder synced between Macs
/// shouldn't hide the icon on all of them at once.
///
/// With the icon hidden, the window still opens when betterlink is opened by
/// hand (Spotlight, Finder, Launchpad), so there is always a way back in.
public enum MenuBarIcon {
    public static let defaultsKey = "showMenuBarIcon"
    /// Where this Mac's settings live while `BETTERLINK_HOME` is set: a domain
    /// for that folder alone, so a test or development run never sees the real
    /// settings or another folder's. Sync's folder and device are among them: a
    /// shared domain let an empty test folder sync as a Mac that deleted everything.
    public static func developmentSuite(home: String) -> String {
        let path = URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let id = SHA256.hash(data: Data(path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return "com.wkoutre.betterlink.development.\(id)"
    }

    /// Never the real settings while `BETTERLINK_HOME` is set.
    public static func defaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        guard let home = environment["BETTERLINK_HOME"], !home.isEmpty else { return .standard }
        // Nil only for the app's own or the global domain, which this never names.
        return UserDefaults(suiteName: developmentSuite(home: home))!
    }

    /// Shown unless it was turned off.
    public static func isShown(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    public static func setShown(_ shown: Bool, in defaults: UserDefaults) {
        defaults.set(shown, forKey: defaultsKey)
    }
}
