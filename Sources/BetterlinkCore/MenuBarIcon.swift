import Foundation
import os

/// Whether betterlink shows its icon in the menu bar. Kept per Mac in
/// UserDefaults, not in rules.json: a settings folder synced between Macs
/// shouldn't hide the icon on all of them at once.
///
/// With the icon hidden, the window still opens when betterlink is opened by
/// hand (Spotlight, Finder, Launchpad), so there is always a way back in.
public enum MenuBarIcon {
    public static let defaultsKey = "showMenuBarIcon"
    /// Where this Mac's settings live while `BETTERLINK_HOME` is set: a domain
    /// for that very folder, so a test or development run never sees the real
    /// settings or another folder's. Sync's folder and device are among them: a
    /// shared domain let an empty test folder sync as a Mac that deleted everything.
    ///
    /// Not the path: a folder deleted and made again there is a new one. An id
    /// file inside says which folder it is, and the inode tells a copy apart.
    public static func developmentSuite(home: String) -> String {
        let folder = URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true)
        let file = folder.appendingPathComponent(".preferences-id")
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Only if there is none: whoever makes it first wins.
        try? Data(UUID().uuidString.utf8).write(to: file, options: .withoutOverwriting)
        guard let data = fm.contents(atPath: file.path), let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text),
              // Through a link, the folder it points to.
              let inode = try? fm.attributesOfItem(atPath: folder.resolvingSymlinksInPath().path)[.systemFileNumber] as? UInt64
        else { return "com.wkoutre.betterlink.development.\(UUID().uuidString)" } // shares nothing, with anyone
        return "com.wkoutre.betterlink.development.\(id.uuidString).\(inode)"
    }

    /// The development domain of each folder this process has used, so it keeps
    /// to one even if the folder is removed under it.
    private static let suites = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    /// Never the real settings while `BETTERLINK_HOME` is set.
    public static func defaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        guard let home = environment["BETTERLINK_HOME"], !home.isEmpty else { return .standard }
        let suite = suites.withLock { known in
            if let s = known[home] { return s }
            let s = developmentSuite(home: home)
            known[home] = s
            return s
        }
        // Nil only for the app's own or the global domain, which this never names.
        return UserDefaults(suiteName: suite)!
    }

    /// Shown unless it was turned off.
    public static func isShown(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) as? Bool ?? true
    }

    public static func setShown(_ shown: Bool, in defaults: UserDefaults) {
        defaults.set(shown, forKey: defaultsKey)
    }
}
