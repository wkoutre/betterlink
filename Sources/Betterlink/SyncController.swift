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
    /// sync settings (SyncDefaults), so two copies on one Mac sync like two Macs.
    private let testDevice = ProcessInfo.processInfo.environment["BETTERLINK_SYNC_DEVICE"]

    /// The sync folder (inside Dropbox, Google Drive or iCloud Drive); nil: off.
    @Published private(set) var folder: URL?
    @Published var selection: SyncSelection { didSet { saveSelection(); session?.selection = selection; schedulePull() } }
    /// One line for the Sync settings: when it last synced, or what is wrong.
    @Published private(set) var status = "Off"
    /// Sidebar Profiles other Macs share that this Mac hasn't added.
    @Published private(set) var offered: [SyncOffer] = []
    /// Offers whose Add or Merge waits for the next sync.
    @Published private(set) var pendingOffers: Set<UUID> = []
    /// Other Macs whose betterlink doesn't know merges yet: a Merge waits for them.
    @Published private(set) var mergeWaitsFor: [String] = []
    /// Sync held back instead of deleting many synced items at once
    /// (SyncGuard); nil while syncing.
    @Published private(set) var held: SyncHold?
    /// What sync deleted here or replaced with another Mac's edit, newest first.
    @Published private(set) var history: [SyncHistoryEntry] = []
    /// Entries asked to be restored, until the next sync does it.
    @Published private(set) var restoring: Set<UUID> = []
    /// The other Macs in the sync folder, with when each last synced.
    @Published private(set) var peers: [SyncPeer] = []
    /// Synced Link Rules whose browser profile this Mac doesn't have: the
    /// Link Rules page marks them.
    @Published private(set) var unresolvedRules: Set<UUID> = []
    /// The profile each unresolved rule was made for on another Mac.
    @Published private(set) var missingProfiles: [UUID: String] = [:]

    private var settings: SettingsFolder?
    private var session: SyncSession?
    private var watchers: [PathWatcher] = []
    private var timer: Timer?
    private var pending: DispatchWorkItem?
    /// Whether the pull waiting to run must run (a timer, a choice made here)
    /// or may be skipped when nothing it reads changed (a file watch).
    private var pendingMustRun = false
    /// What the sync reads, as the last pull that finished left it. Nil until
    /// one has, and after one failed: the next pull then runs whatever asked.
    private var pulledInputs: SyncInputs?
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
        folder = SyncDefaults.folder(in: MenuBarIcon.defaults())
        selection = SyncDefaults.selection(in: MenuBarIcon.defaults())
    }

    /// `betterlink sync set` wrote the folder or the selection from another
    /// process: take them up as if they were chosen here.
    func reloadSettings() {
        let saved = SyncDefaults.selection(in: defaults)
        if saved != selection { selection = saved }
        let now = SyncDefaults.folder(in: defaults)
        guard now?.standardizedFileURL != folder?.standardizedFileURL else { return }
        folder = now
        note(now.map { "Sync folder is now \($0.path)." } ?? "Sync is off on this Mac.")
        forgetHold()
        restart()
    }

    /// Called when the settings folder is known or changes.
    func attach(settings: SettingsFolder, note: @escaping (String) -> Void) {
        self.settings = settings
        self.note = note
        restart()
    }

    func choose(folder url: URL) {
        folder = url
        SyncDefaults.setFolder(url, in: defaults)
        note("Sync folder is now \(url.path).")
        forgetHold()
        restart()
    }

    /// Asks for the sync folder with the system's panel (the Sync page, and the tour).
    func chooseFolderWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Sync Here"
        panel.message = "Pick a folder Dropbox, Google Drive or iCloud Drive keeps in sync."
        if panel.runModal() == .OK, let url = panel.url { choose(folder: url) }
    }

    func turnOff() {
        folder = nil
        SyncDefaults.setFolder(nil, in: defaults)
        note("Sync is off on this Mac. Its file stays in the sync folder, so other Macs keep everything it shared.")
        forgetHold()
        restart()
    }

    /// Another folder, or none: a hold and its answer were about the old one.
    private func forgetHold() {
        guard let settings else { return }
        try? SyncLocalStore(folder: settings).update { $0.held = nil; $0.decision = nil }
    }

    /// A settings file changed on this Mac (AppModel's reloads, which also
    /// see editors that save in place): sync it out.
    func localChanged() { if session != nil { schedulePull(mustRun: false) } }

    /// The sidebar saved which folders are open and nothing else, which
    /// doesn't sync: if that save started from the sidebar.json the last pull
    /// saw, the watch it sets off finds nothing to do (`SyncInputs.moved`).
    func savedOnlyOpenFolders(before: FileSignature?, after: FileSignature?) {
        guard let settings else { return }
        pulledInputs?.moved(SidebarStore(folder: settings).file, from: before, to: after)
    }

    /// Adds a Sidebar Profile another Mac shares, with all its parts, on the
    /// next sync (`betterlink sync add`). The sync copies it in before it
    /// starts syncing it: a selected profile this Mac doesn't have reads as
    /// deleted here.
    func add(_ offer: SyncOffer) {
        request(offer) { if !($0.adding ?? []).contains(offer.id) { $0.adding = ($0.adding ?? []) + [offer.id] } }
    }

    /// Makes an offer and this Mac's profile with the same name one Sidebar
    /// Profile on every Mac, with everything in both (`betterlink sync merge`).
    func merge(_ offer: SyncOffer) {
        let group = offered.filter { SyncModel.sameName($0.name, offer.name) }.map(\.id) + [offer.sameNameAs].compactMap { $0 }
        request(offer) { $0.merging = ($0.merging ?? []) + [Array(Set(group + [offer.id])).sorted { $0.uuidString < $1.uuidString }] }
    }

    private func request(_ offer: SyncOffer, _ change: (inout SyncLocal) -> Void) {
        guard let settings else { return }
        do {
            try SyncLocalStore(folder: settings).update(change)
            pendingOffers.insert(offer.id)
        } catch {
            status = "Couldn't save that: \(error.localizedDescription)"
        }
        schedulePull()
    }

    /// Answers a hold: delete those items on every Mac once, or keep them
    /// and take the shared ones back on this Mac. `betterlink sync resolve`
    /// writes the same answer.
    func resolveHold(_ choice: SyncDecision.Choice) {
        guard let settings else { return }
        do {
            let saved = try SyncLocalStore(folder: settings).update { $0.answer(choice) }
            guard saved.held != nil else { note("Nothing is paused."); return }
            note(choice == .delete ? "Deleting the held items on every Mac." : "Keeping the held items; this Mac takes them back from the others.")
        } catch {
            status = "Couldn't save the answer: \(error.localizedDescription)"
        }
        schedulePull()
    }

    /// Puts back what a history entry deleted or replaced, as a new edit on
    /// this Mac (`betterlink sync restore`).
    func restore(_ entry: SyncHistoryEntry) {
        guard let settings else { return }
        do {
            try SyncLocalStore(folder: settings).update { if !$0.restore.contains(entry.id) { $0.restore.append(entry.id) } }
        } catch {
            status = "Couldn't restore: \(error.localizedDescription)"
        }
        refreshNotes()
        schedulePull()
    }

    /// The hold and the history, as sync-local.json has them now.
    private func refreshNotes() {
        guard let settings else { held = nil; history = []; restoring = []; unresolvedRules = []; missingProfiles = [:]; return }
        let notes = SyncLocalStore(folder: settings).load()
        held = notes.held
        history = notes.history
        restoring = Set(notes.restore)
        unresolvedRules = folder == nil ? [] : Set(notes.unresolvedRules ?? [])
        missingProfiles = folder == nil ? [:] : Dictionary(uniqueKeysWithValues: (notes.missingProfiles ?? [:])
            .compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
    }

    // MARK: - Running

    private func restart() {
        watchers = []; timer?.invalidate(); timer = nil; session = nil; offered = []
        pulledInputs = nil
        peers = []
        if folder == nil, let settings {
            // Off: no rule is unresolved any more (the CLI's rules list reads this too).
            try? SyncLocalStore(folder: settings).update { $0.unresolvedRules = nil; $0.missingProfiles = nil }
        }
        refreshNotes()
        guard let folder, let settings else { status = "Off"; held = nil; return }
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
        // An Add or Merge saves the selection before the sidebar it describes.
        let d = defaults
        session?.saveSelection = { SyncDefaults.setSelection($0, in: d) }
        // Another Mac's file landing, or a local settings change: sync.
        if let w = PathWatcher(url: f.devices, debounce: 0.3, onChange: { [weak self] in
            MainActor.assumeIsolated { self?.schedulePull(mustRun: false) }
        }) { watchers.append(w) }
        if let w = PathWatcher(url: settings.directory, debounce: 0.5, onChange: { [weak self] in
            MainActor.assumeIsolated { self?.schedulePull(mustRun: false) }
        }) { watchers.append(w) }
        // A cloud app can replace files without the folder noticing; look anyway.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePull() }
        }
        // Any time about then: macOS can do it when the Mac is awake anyway.
        timer?.tolerance = 10
        schedulePull()
    }

    /// A pull a moment from now. `mustRun` false (a file watch): skipped
    /// when nothing the sync reads changed since the last pull. The 30 second
    /// timer and every choice made here always pull.
    private func schedulePull(mustRun: Bool = true) {
        PerfTrace.mark("sync pull scheduled")
        pending?.cancel()
        pendingMustRun = pendingMustRun || mustRun
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.pull() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: item)
    }

    private func pull() {
        let mustRun = pendingMustRun
        pendingMustRun = false
        if !mustRun, let seen = pulledInputs, let inputs = currentInputs(), inputs == seen {
            PerfTrace.mark("sync pull skipped: nothing it reads changed")
            return
        }
        PerfTrace.span("sync pull") { pullNow() }
    }

    private func currentInputs() -> SyncInputs? {
        guard let settings, let folder else { return nil }
        return SyncInputs.of(settings: settings, sync: SyncFolder(folder))
    }

    private func pullNow() {
        guard let session else { return }
        // Read before the pull, so a change that lands while it runs is never
        // taken as seen. Its own writes make the next watch pull once more.
        let inputs = currentInputs()
        pulledInputs = nil
        let wasHeld = held?.ids
        defer {
            refreshNotes()
            // Whatever the outcome, a selection the sync saved is this Mac's now.
            if session.selection != selection { selection = session.selection }
            mergeWaitsFor = session.mergeWaitsFor
        }
        do {
            let r = try session.pull()
            if !r.recorded.isEmpty {
                note("Sync changed \(r.recorded.count) item(s) here from another Mac. Sync settings lists them under Recently changed by sync, with Restore.")
            }
            if let bak = r.configReplaced {
                note("config.ts was replaced by a newer one from another Mac. Yours is kept as \(bak.lastPathComponent).")
            }
            let unresolved = Set(r.notes.unresolvedRules)
            if unresolved != lastUnresolved, !unresolved.isEmpty {
                note("\(unresolved.count) synced rule(s) point at a Browser Profile this Mac doesn't have; each opens in the fallback, or the same browser's Default profile when none is set.")
            }
            lastUnresolved = unresolved
            if r.unsafe != lastUnsafe {
                for u in r.unsafe { note("Sync refused another Mac's file, \(u).") }
            }
            lastUnsafe = r.unsafe
            if !r.notes.orphansMovedToTop.isEmpty {
                note("\(r.notes.orphansMovedToTop.count) saved link(s) or folder(s) were in a folder another Mac deleted; they are at the top of the sidebar now.")
            }
            if !r.notes.cyclesBroken.isEmpty { note("Two Macs moved folders into each other; one is at the top of the sidebar now.") }
            if !r.newer.isEmpty { note("Another Mac uses a newer betterlink; update this one to sync with it.") }
            let others = Set(session.otherDevices)
            peers = session.peers
            status = "Synced \(Date().formatted(date: .omitted, time: .shortened))" + (others.isEmpty ? "" : " with \(others.count) other Mac\(others.count == 1 ? "" : "s")")
            offered = session.offers()
            pendingOffers = []
            pulledInputs = inputs
        } catch let e as SyncSession.Held {
            if wasHeld != e.hold.ids { note(e.hold.reason) }
            let n = e.hold.ids.count
            status = "Paused: this Mac would delete \(n) synced item\(n == 1 ? "" : "s"). Choose below."
        } catch {
            status = "Couldn't sync: \(error.localizedDescription)"
        }
    }

    private func saveSelection() {
        SyncDefaults.setSelection(selection, in: defaults)
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
        ProfileCatalog.resolveSynced(browser: Browser.known(bundleId: browser), directory: directory, identity: who,
                                     localState: localState(browser))
    }
}
