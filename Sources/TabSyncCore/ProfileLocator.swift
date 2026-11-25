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

/// Which browser window, in which profile, the window in front is.
public enum WindowMatch {
    public struct Hit: Equatable, Sendable {
        public var session: String
        public var windowId: Int
    }

    /// The browser's focused window. The browser tells each profile's copy of
    /// the extension which of its windows has focus, and the others "none of
    /// mine" (`windows.onFocusChanged`), so while the browser is in front
    /// exactly one window across all its profiles is focused: the one in front.
    /// This tells apart windows of one profile at the same size and place.
    /// Then, when focus is unknown (an event not in yet), the window whose
    /// reported frame is closest to `frame`.
    public static func front(frame: WindowBounds?, in sessions: [BrowserSession]) -> Hit? {
        let focused = sessions.flatMap { s in
            s.store.orderedWindows.filter(\.window.focused).map { Hit(session: s.id, windowId: $0.id) }
        }
        if focused.count == 1 { return focused[0] }
        return frame.flatMap { best(for: $0, in: sessions) }
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

    /// What the sidebar may show for the browser window in front.
    public enum Found: Equatable, Sendable {
        case window(Hit)
        /// No copy of the extension is connected for this browser.
        case notConnected
        /// The browser is connected, but this window is not one the extension
        /// reports: an Incognito window it isn't allowed in, or a window of a
        /// profile without the extension.
        case unseen
    }

    /// The browser window behind the window in front, or the reason there is
    /// none. Never a guess: a click in the sidebar switches, closes and opens
    /// tabs, and doing that in another window than the one beside it is worse
    /// than showing nothing.
    ///
    /// 1. The browser's one focused window (see `front`).
    /// 2. With no single focused window (betterlink's own window is in front,
    ///    or an event is still on its way): the one window at this frame whose
    ///    active tab titles the window. An Incognito window the extension
    ///    can't see often sits exactly on a regular one, so the frame alone
    ///    isn't enough when there is a title to compare.
    /// - Parameters:
    ///   - sessions: this browser's sessions (every profile's copy of the extension).
    ///   - title: the window's title, which Chromium starts with the active tab's.
    public static func find(frame: WindowBounds?, title: String, in sessions: [BrowserSession],
                            tolerance: Double = 40) -> Found {
        guard !sessions.isEmpty else { return .notConnected }
        let all = sessions.flatMap { s in s.store.orderedWindows.map { (hit: Hit(session: s.id, windowId: $0.id), entry: $0) } }
        let focused = all.filter(\.entry.window.focused)
        if focused.count == 1 { return .window(focused[0].hit) }

        func titled(_ e: TabStore.WindowEntry) -> Bool? {
            guard !title.isEmpty, let active = e.tabs.first(where: \.active)?.title, !active.isEmpty else { return nil }
            return title.hasPrefix(active)
        }
        let atFrame = all.filter { w in
            guard let frame, let b = w.entry.window.bounds else { return false }
            return b.distance(to: frame) <= tolerance
        }
        // At this frame and titled by it; or, when a title can't be compared
        // (a page still loading), the only window at this frame.
        let both = atFrame.filter { titled($0.entry) == true }
        if both.count == 1 { return .window(both[0].hit) }
        if atFrame.count == 1, titled(atFrame[0].entry) == nil { return .window(atFrame[0].hit) }
        // No frames to go by (the browser never reported them): the title alone,
        // when exactly one window has it.
        if frame == nil || all.allSatisfy({ $0.entry.window.bounds == nil }) {
            let byTitle = all.filter { titled($0.entry) == true }
            if byTitle.count == 1 { return .window(byTitle[0].hit) }
        }
        return .unseen
    }
}
