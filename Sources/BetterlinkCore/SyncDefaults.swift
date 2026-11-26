import Foundation

/// Where this Mac keeps its Sync settings (the folder, and what syncs), so the
/// app and `betterlink sync` read and write the same keys. Per Mac, in
/// UserDefaults: each Mac picks its own folder path and its own selection.
public enum SyncDefaults {
    /// BETTERLINK_SYNC_DEVICE (tests) gives a copy its own settings, so two
    /// copies on one Mac sync like two Macs.
    public static func key(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment["BETTERLINK_SYNC_DEVICE"].map { "\($0).\(name)" } ?? name
    }

    /// The sync folder; nil when Sync is off.
    public static func folder(in defaults: UserDefaults) -> URL? {
        defaults.string(forKey: key("sync.folder")).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    public static func setFolder(_ folder: URL?, in defaults: UserDefaults) {
        if let folder { defaults.set(folder.path, forKey: key("sync.folder")) }
        else { defaults.removeObject(forKey: key("sync.folder")) }
    }

    /// What syncs. Until chosen: the global settings, and no Sidebar Profile.
    public static func selection(in defaults: UserDefaults) -> SyncSelection {
        defaults.data(forKey: key("sync.selection")).flatMap { try? JSONDecoder().decode(SyncSelection.self, from: $0) }
            ?? SyncSelection(global: true, profiles: [:])
    }

    public static func setSelection(_ selection: SyncSelection, in defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(selection) { defaults.set(data, forKey: key("sync.selection")) }
    }
}
