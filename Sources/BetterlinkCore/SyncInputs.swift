import Foundation

/// The files a sync reads on this Mac, as their signatures (`FileSignature`):
/// rules.json, sidebar.json, config.ts, sync-local.json and every device file
/// in the sync folder. A pull that a file watch asked for is skipped while
/// these are as the last pull left them, so the watch firing for a file the
/// sync doesn't read (or for the pull's own writes) costs nothing.
///
/// Opening or closing a folder rewrites sidebar.json but doesn't sync: the
/// save moves the signature this holds along with it (`moved`), so it reads
/// as no change. Without that, every folder clicked set off a pull on the main
/// thread (40 to 50 ms) about 0.8 s later, mid-motion when clicks come quickly.
public struct SyncInputs: Equatable, Sendable {
    public private(set) var files: [String: FileSignature?]

    public static func of(settings: SettingsFolder, sync: SyncFolder) -> SyncInputs {
        var files: [String: FileSignature?] = [:]
        let local = [settings.rulesFile, SidebarStore(folder: settings).file, settings.configFile,
                     SyncLocalStore(folder: settings).file]
        for url in local { files[url.standardizedFileURL.path] = FileSignature.of(url) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sync.devices.path)) ?? []
        for n in names.sorted() {
            let url = sync.devices.appendingPathComponent(n)
            files[url.standardizedFileURL.path] = FileSignature.of(url)
        }
        return SyncInputs(files: files)
    }

    /// A save of `file` that read it as `from` and left it as `to`. True when
    /// that is the file these inputs hold, which then hold `to`: nothing else
    /// changed it in between. False otherwise, and nothing is moved.
    @discardableResult
    public mutating func moved(_ file: URL, from: FileSignature?, to: FileSignature?) -> Bool {
        let key = file.standardizedFileURL.path
        guard let held = files[key], held == from else { return false }
        files[key] = to
        return true
    }
}
