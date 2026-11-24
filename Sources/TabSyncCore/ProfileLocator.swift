import Foundation

/// Which browser profile a copy of the Tabs extension runs in.
///
/// Every profile runs its own copy of the extension, and each copy keeps a
/// random id in its extension storage (`chrome.storage.local`), which Chromium
/// writes to `<profile folder>/Local Extension Settings/<extension id>/`. The id
/// is found by reading those files: no browser API names the profile.
public enum ProfileLocator {
    /// The profile folder name (`Default`, `Profile 1`) under `dataFolder` whose
    /// extension storage holds `instance`, or nil.
    public static func directory(instance: String, dataFolder: URL,
                                 extensionId: String = HostRegistration.extensionId) -> String? {
        guard !instance.isEmpty, let needle = instance.data(using: .utf8),
              let profiles = try? FileManager.default.contentsOfDirectory(atPath: dataFolder.path) else { return nil }
        for profile in profiles.sorted() {
            let store = dataFolder.appendingPathComponent(profile)
                .appendingPathComponent("Local Extension Settings").appendingPathComponent(extensionId)
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: store.path) else { continue }
            for f in files where f.hasSuffix(".log") || f.hasSuffix(".ldb") {
                // LevelDB keeps fresh writes uncompressed in .log files; a short
                // value stays a literal run even after compaction.
                guard let data = FileManager.default.contents(atPath: store.appendingPathComponent(f).path),
                      data.count < 8 << 20 else { continue }
                if data.range(of: needle) != nil { return profile }
            }
        }
        return nil
    }
}

/// Which browser window, in which profile, the window in front is.
public enum WindowMatch {
    public struct Hit: Equatable, Sendable {
        public var session: String
        public var windowId: Int
    }

    /// The window whose reported frame is closest to `frame` (Accessibility
    /// coordinates), across every session of that browser process. Frames more
    /// than `tolerance` apart in total don't count.
    public static func best(for frame: WindowBounds, in sessions: [BrowserSession], tolerance: Double = 40) -> Hit? {
        var best: (Hit, Double)?
        for s in sessions {
            for w in s.store.orderedWindows {
                guard let b = w.window.bounds else { continue }
                let d = b.distance(to: frame)
                if d <= tolerance, d < (best?.1 ?? .infinity) { best = (Hit(session: s.id, windowId: w.id), d) }
            }
        }
        return best?.0
    }
}
