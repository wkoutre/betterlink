import Foundation

/// Which browser profile a copy of the Tabs extension runs in.
///
/// Every profile runs its own copy of the extension, and each copy keeps a
/// random id in its extension storage (`chrome.storage.local`), which Chromium
/// writes to `<profile folder>/Local Extension Settings/<extension id>/`. The id
/// is found by reading those files: no browser API names the profile.
public enum ProfileLocator {
    /// Seconds after a look before a session's profile is looked for again
    /// (each look reads the profile folders' extension storage and Local
    /// State): one found is read again every 30 s, so a renamed or recolored
    /// profile shows; one not found yet every 5 s. `lookingFor`: seconds
    /// since its first look.
    public static func lookAgain(found: Bool, lookingFor: Double) -> Double {
        found ? 30 : 5
    }

    /// The profile folder name (`Default`, `Profile 1`) under `dataFolder` whose
    /// extension storage holds `instance`, or nil.
    public static func directory(instance: String, dataFolder: URL,
                                 extensionId: String = HostRegistration.extensionId) -> String? {
        // The random part: never repeats anything else in the store.
        let random = instance.components(separatedBy: "betterlink-instance-").last ?? instance
        guard !random.isEmpty, let needle = random.data(using: .utf8),
              let profiles = try? FileManager.default.contentsOfDirectory(atPath: dataFolder.path) else { return nil }
        for profile in profiles.sorted() {
            let store = dataFolder.appendingPathComponent(profile)
                .appendingPathComponent("Local Extension Settings").appendingPathComponent(extensionId)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { continue }
            for f in files where f.hasSuffix(".log") || f.hasSuffix(".ldb") {
                // LevelDB keeps fresh writes uncompressed in .log files. After
                // compaction (.ldb) blocks may be Snappy-compressed, which can
                // fold the "betterlink" prefix into a back-reference to the key,
                // so only the random part of the id is searched for.
                guard let data = FileManager.default.contents(atPath: store.appendingPathComponent(f).path),
                      data.count < 8 << 20 else { continue }
                if data.range(of: needle) != nil { return profile }
            }
        }
        return nil
    }
}
