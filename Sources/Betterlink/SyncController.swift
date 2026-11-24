import AppKit
import BetterlinkCore
import Foundation

/// Sync between Macs (docs/sync.md): which folder, what syncs, and keeping it
/// live. Everything here is per Mac; the merging is SyncSession's.
@MainActor
final class SyncController: ObservableObject {
    static let shared = SyncController()

    private let defaults = MenuBarIcon.defaults()
    /// BETTERLINK_SYNC_DEVICE (tests): this copy's device id, with its own
    /// sync settings, so two copies on one Mac sync like two Macs.
    private let testDevice = SyncController.testDeviceID
    private static let testDeviceID = ProcessInfo.processInfo.environment["BETTERLINK_SYNC_DEVICE"]
    private func key(_ k: String) -> String { Self.key(k) }
    private static func key(_ k: String) -> String { testDeviceID.map { "\($0).\(k)" } ?? k }

    /// The sync folder (inside Dropbox, Google Drive or iCloud Drive); nil: off.
    @Published private(set) var folder: URL?
    @Published var selection: SyncSelection { didSet { saveSelection(); session?.selection = selection; schedulePull() } }
    /// One line for the Sync settings: when it last synced, or what is wrong.
    @Published private(set) var status = "Off"
    /// Sidebar Profiles other Macs share that this Mac hasn't added.
    @Published private(set) var offered: [(id: UUID, name: String)] = []

    private var settings: SettingsFolder?
    private var session: SyncSession?
    private var watchers: [PathWatcher] = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    private var note: (String) -> Void = { _ in }
    /// What the Log last said about rules with no matching profile and about
    /// refused device files, so it speaks only when that changes.
    private var lastUnresolved: Set<UUID> = []
    private var lastUnsafe: [String] = []

    /// This Mac, as other Macs' Logs name it.
    lazy var deviceName = testDevice.map { "Test \($0)" } ?? Host.current().localizedName ?? "Mac"
    private lazy var device: String = {
        if let t = testDevice { return t }
        if let d = defaults.string(forKey: "sync.device") { return d }
        let d = UUID().uuidString
        defaults.set(d, forKey: "sync.device")
        return d
    }()

    private init() {
        folder = MenuBarIcon.defaults().string(forKey: Self.key("sync.folder")).map { URL(fileURLWithPath: $0, isDirectory: true) }
        selection = MenuBarIcon.defaults().data(forKey: Self.key("sync.selection")).flatMap { try? JSONDecoder().decode(SyncSelection.self, from: $0) }
            ?? SyncSelection(global: true, profiles: [:])
    }

    /// Called when the settings folder is known or changes.
    func attach(settings: SettingsFolder, note: @escaping (String) -> Void) {
        self.settings = settings
        self.note = note
        restart()
    }

    func choose(folder url: URL) {
        folder = url
        defaults.set(url.path, forKey: key("sync.folder"))
        note("Sync folder is now \(url.path).")
        restart()
    }

    func turnOff() {
        folder = nil
        defaults.removeObject(forKey: key("sync.folder"))
        note("Sync is off on this Mac. Its file stays in the sync folder, so other Macs keep everything it shared.")
        restart()
    }

    /// A settings file changed on this Mac (AppModel's reloads, which also
    /// see editors that save in place): sync it out.
    func localChanged() { if session != nil { schedulePull() } }

    /// Adds a Sidebar Profile another Mac shares, with all its parts.
    func add(_ id: UUID) { selection.profiles[id] = .init() }

    // MARK: - Running

    private func restart() {
        watchers = []; timer?.invalidate(); timer = nil; session = nil; offered = []
        guard let folder, let settings else { status = "Off"; return }
        guard FileManager.default.fileExists(atPath: folder.path) else {
            status = "Paused: the sync folder isn't there (\(folder.lastPathComponent)). It resumes when it is back."
            // Check again later: the cloud app may still be starting.
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.restart() }
            }
            return
        }
        let f = SyncFolder(folder)
        try? FileManager.default.createDirectory(at: f.devices, withIntermediateDirectories: true)
        session = SyncSession(settings: settings, folder: f, device: device, name: deviceName, selection: selection,
                              identity: { [weak self] in self?.identity($0) ?? ProfileIdentity(name: nil, account: nil) },
                              resolve: { [weak self] b, d, who in self?.resolve(b, d, who) })
        // Another Mac's file landing, or a local settings change: sync.
        if let w = PathWatcher(url: f.devices, debounce: 0.3, onChange: { [weak self] in
            MainActor.assumeIsolated { self?.schedulePull() }
        }) { watchers.append(w) }
        if let w = PathWatcher(url: settings.directory, debounce: 0.5, onChange: { [weak self] in
            MainActor.assumeIsolated { self?.schedulePull() }
        }) { watchers.append(w) }
        // A cloud app can replace files without the folder noticing; look anyway.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePull() }
        }
        schedulePull()
    }

    private func schedulePull() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.pull() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func pull() {
        guard let session else { return }
        do {
            let r = try session.pull()
            if let bak = r.configReplaced {
                note("config.ts was replaced by a newer one from another Mac. Yours is kept as \(bak.lastPathComponent).")
            }
            let unresolved = Set(r.notes.unresolvedRules)
            if unresolved != lastUnresolved, !unresolved.isEmpty {
                note("\(unresolved.count) synced rule(s) point at a browser profile this Mac doesn't have; they open in the fallback.")
            }
            lastUnresolved = unresolved
            if r.unsafe != lastUnsafe {
                for u in r.unsafe { note("Sync refused another Mac's file, \(u).") }
            }
            lastUnsafe = r.unsafe
            if !r.notes.orphansMovedToTop.isEmpty {
                note("\(r.notes.orphansMovedToTop.count) saved item(s) were in a folder another Mac deleted; they are at the top of the sidebar now.")
            }
            if !r.notes.cyclesBroken.isEmpty { note("Two Macs moved folders into each other; one is at the top of the sidebar now.") }
            if !r.newer.isEmpty { note("Another Mac uses a newer betterlink; update this one to sync with it.") }
            let others = Set(session.otherDevices)
            status = "Synced \(Date().formatted(date: .omitted, time: .shortened))" + (others.isEmpty ? "" : " with \(others.count) other Mac\(others.count == 1 ? "" : "s")")
            offered = session.offeredProfiles(localIDs: Set(selection.profiles.keys))
        } catch {
            status = "Couldn't sync: \(error.localizedDescription)"
        }
    }

    private func saveSelection() {
        if let d = try? JSONEncoder().encode(selection) { defaults.set(d, forKey: key("sync.selection")) }
    }

    // MARK: - Browser profiles on this Mac

    private func localState(_ browser: String) -> Data? {
        guard let folder = Browser.known(bundleId: browser)?.dataFolder else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").appendingPathComponent(folder)
        return FileManager.default.contents(atPath: root.appendingPathComponent("Local State").path)
    }

    private func identity(_ ref: ProfileRef) -> ProfileIdentity {
        guard let data = localState(ref.browser) else { return ProfileIdentity(name: nil, account: nil) }
        let name = ProfileCatalog.parse(localStateJSON: data, browser: ref.browser).profiles.first { $0.directory == ref.directory }?.name
        return ProfileIdentity(name: name, account: ProfileCatalog.accounts(localStateJSON: data)[ref.directory])
    }

    private func resolve(_ browser: String, _ directory: String, _ who: ProfileIdentity) -> String? {
        // Safari and Firefox have no profiles here to match: the same name works.
        guard let known = Browser.known(bundleId: browser), known.dataFolder != nil else { return directory }
        guard let data = localState(browser) else { return nil }
        let profiles = ProfileCatalog.parse(localStateJSON: data, browser: browser).profiles
        return ProfileCatalog.resolve(who, profiles: profiles, accounts: ProfileCatalog.accounts(localStateJSON: data))
    }
}
