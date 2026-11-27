import AppKit
import os
import BetterlinkCore
import SwiftUI
import TabSyncCore

/// SwiftUI has its own `Tab` (macOS 15), so name the browser's explicitly.
typealias BrowserTab = TabSyncCore.Tab

/// Every open tab in every connected browser, live, for the
/// sidebar. The browser pushes each change through the Tabs extension and
/// betterlink-tabhost the instant it happens; nothing here polls.
@MainActor
final class TabsModel: ObservableObject {
    static let shared = TabsModel()

    @Published private(set) var sessions: [BrowserSession] = []
    /// Browser profiles, by the extension's instance id (see ProfileLocator):
    /// which one, its name ("Claude", "Work"), and the color the browser
    /// paints its window frame, when it has one.
    @Published private(set) var profiles: [String: (ref: ProfileRef, name: String, color: UInt32?)] = [:]
    private var profileLookups: [String: Date] = [:]
    /// When each instance's profile was first looked for.
    private var profileFirstLookups: [String: Date] = [:]
    @Published private(set) var registrationError: String?
    /// Bumped after a register/unregister so the browser rows re-read their state.
    @Published private(set) var registrationVersion = 0
    /// The version of the Tabs extension in the folder browsers load it from
    /// (`ExtensionCopy.folder`), or nil when nothing is there.
    @Published private(set) var extensionVersion: String?
    @Published private(set) var extensionError: String?
    /// Sessions already asked to reload their extension: each is asked once.
    private var askedToReload: Set<String> = []
    private var hub: SyncHub?
    /// When each connection's list was last checked against its browser.
    private var refreshPacer = RefreshPacer()
    private var frontObserver: NSObjectProtocol?

    /// Starts listening the first time the Sidebar page opens or the sidebar
    /// turns on, so betterlink does no tab work for anyone who uses neither.
    func start() {
        guard hub == nil else { return }
        refreshExtension()
        // The hub hands on a title or icon change once, then holds the rest
        // until `publish()` collects the lists: under churn the main thread
        // hears of what tabs show once per publish, not once per message.
        let hub = SyncHub(holdingContent: true, onLine: { [weak self] path, m in
            // Two things saved links' held tabs need the moment the browser says
            // them: the tab an open made (its ack), and a tab closed on its own.
            if m.type == "ack", let id = m.id {
                let ok = m.ok == true
                DispatchQueue.main.async {
                    if let tab = m.tabId { SidebarHoldsModel.shared.opened(command: id, tab: tab) }
                    self?.answered(command: id, ok: ok)
                }
            } else if m.type == "event", m.kind == "tabRemoved", m.isWindowClosing != true, let tab = m.tabId {
                DispatchQueue.main.async { SidebarHoldsModel.shared.closed(tab: tab, socketPath: path) }
            }
            if m.type == "event", m.kind == "windowFocused" {
                DragTrace.log("focus: the extension says window \(m.windowId ?? -1) has it (\(path))")
            }
            // Whether the change that follows is only what a tab shows.
            if !PublishPacer.isContent(m) { self?.urgent.withLock { $0 = true } }
        }, onChange: { [weak self] s in
            guard let self else { return }
            // Taken here, on the hub's queue, so it belongs to this change.
            let urgent = self.urgent.withLock { u in defer { u = false }; return u || s.count != self.seen.withLock({ $0 }) }
            self.seen.withLock { $0 = s.count }
            DispatchQueue.main.async {
                // Every list, not only the ones drawn: a held tab's address
                // must be known the moment it changes, before it closes (the
                // hub hands an address change on at once).
                SidebarHoldsModel.shared.settle(s, links: SidebarLibraryModel.shared.library.allLinkIDs)
                self.changed(s, urgent: urgent)
            }
        })
        self.hub = hub
        hub.start()
        // A browser coming to the front has its lists checked, at most once a
        // minute each (`RefreshPacer`): a list that went wrong without a
        // sequence gap is put right before anyone looks at it for long.
        frontObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let pid = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated { if let pid { self?.browserInFront(pid) } }
        }
    }

    private func browserInFront(_ pid: pid_t) {
        let now = CACurrentMediaTime()
        for s in sessions where s.browserPid == Int(pid) && refreshPacer.browserInFront(s.id, now: now) {
            hub?.send(.refresh(), to: s.socketPath)
        }
    }

    /// What the Sidebar page says under a browser's row: which of its
    /// profiles have the Tabs extension connected, and on what version.
    func connections(_ b: Browser) -> ExtensionConnections {
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: b.bundleId).isEmpty
        let mine = sessions.filter { NSRunningApplication(processIdentifier: pid_t($0.browserPid))?.bundleIdentifier == b.bundleId }
        return ExtensionConnections(running: running,
                                    sessions: mine.map { (name: $0.instance.flatMap { profiles[$0]?.name }, version: $0.extensionVersion) },
                                    folderVersion: extensionVersion)
    }

    /// How often, at most, what tabs show goes on while it keeps changing
    /// (`PublishPacer.interval`; the sidebar says which). When it gets
    /// shorter, what was held back goes on at once.
    var interval = PublishPacer.interval(sidebarOnScreen: false, browserInFront: false) {
        didSet { if interval < oldValue, latest != nil { publish() } }
    }
    /// The tab lists as last handed on, when not published yet. The hub may
    /// hold newer titles and icons: `publish()` collects those.
    private var latest: [BrowserSession]?
    private var pacer = PublishPacer()
    /// A paced publish waiting to happen; one that goes early takes its place.
    private var later: DispatchWorkItem?
    private nonisolated let urgent = OSAllocatedUnfairLock(initialState: false)
    private nonisolated let seen = OSAllocatedUnfairLock(initialState: 0)

    private func changed(_ s: [BrowserSession], urgent: Bool) {
        latest = s
        switch pacer.changed(urgent: urgent, now: CACurrentMediaTime(), interval: interval) {
        case .now: publish()
        case .after(let seconds):
            let work = DispatchWorkItem { [weak self] in self?.publish() }
            later?.cancel()
            later = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        case .waiting: break
        }
    }

    private func publish() {
        later?.cancel()
        later = nil
        guard let handed = latest else { return }
        latest = nil
        let s = hub?.collect() ?? handed
        let now = CACurrentMediaTime()
        pacer.published(now: now)
        sessions = s
        for x in s { refreshPacer.connected(x.id, now: now) }
        refreshPacer.keep(Set(s.map(\.id)))
        lookUpProfiles(s)
        reloadOutdatedExtensions(s)
    }

    /// The browser a session runs in and the folder its profiles live in.
    nonisolated static func profileFolder(of s: BrowserSession) -> (browser: Browser, root: URL)? {
        guard let app = NSRunningApplication(processIdentifier: pid_t(s.browserPid)),
              let browser = app.bundleIdentifier.flatMap({ Browser.known(bundleId: $0) }),
              let folder = browser.dataFolder else { return nil }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support").appendingPathComponent(folder)
        return (browser, root)
    }

    /// Which profile holds the extension copy `instance`, its name and its
    /// color. Reads files: off the main thread.
    nonisolated static func readProfile(instance: String, _ browser: Browser, _ root: URL) -> (ProfileRef, String, UInt32?)? {
        guard let dir = ProfileLocator.directory(instance: instance, dataFolder: root) else { return nil }
        let state = FileManager.default.contents(atPath: root.appendingPathComponent("Local State").path)
        let name = state.flatMap { ProfileCatalog.parse(localStateJSON: $0, browser: browser.bundleId)
            .profiles.first { $0.directory == dir }?.name } ?? dir
        let ref = ProfileRef(browser: browser.bundleId, directory: dir)
        // A custom color theme's own color first (it is what the frame
        // shows), else the frame color Chrome records for the profile.
        let prefs = FileManager.default.contents(atPath: root.appendingPathComponent(dir).appendingPathComponent("Preferences").path)
        let color = prefs.flatMap { ProfileCatalog.themeColor(preferencesJSON: $0) }
            ?? state.flatMap { ProfileCatalog.frameColor(localStateJSON: $0, directory: dir) }
        return (ref, name, color)
    }

    /// A session's profile name, at once (the command line has no time to wait
    /// for the background look). Nil when it can't be told.
    nonisolated static func profileName(of s: BrowserSession) -> String? {
        guard let instance = s.instance, let place = profileFolder(of: s) else { return nil }
        return readProfile(instance: instance, place.browser, place.root)?.1
    }

    /// What the sidebar calls a connected browser profile: "Work (Google Chrome)",
    /// or the browser alone while its profile isn't known, numbered when two
    /// read the same (see `TabTransfer.labels`).
    func label(of s: BrowserSession) -> String {
        TabTransfer.labels(sessions.map { (id: $0.id, base: baseLabel(of: $0)) })[s.id] ?? baseLabel(of: s)
    }

    private func baseLabel(of s: BrowserSession) -> String {
        guard let name = s.instance.flatMap({ profiles[$0]?.name }), !name.isEmpty else { return s.browser }
        return "\(name) (\(s.browser))"
    }

    /// The page in front of `s`'s focused window, to tell apart two profiles
    /// whose names can't be read.
    func frontTitle(of s: BrowserSession) -> String? {
        let windows = s.store.orderedWindows.filter { $0.window.isNormal && !$0.window.incognito }
        let window = windows.first { $0.window.focused } ?? windows.first
        guard let title = window?.tabs.first(where: \.active)?.title, !title.isEmpty else { return nil }
        return title
    }

    // MARK: Sending a tab to another profile or browser

    private var transfers = TabTransfer()

    /// The other connected profiles and browsers `tab` can go to from window
    /// `incognito` or not, by their sidebar label. Empty when its page can't
    /// be sent (a browser's own page, a blank tab).
    func sendTargets(for tab: BrowserTab, from s: BrowserSession, incognito: Bool) -> [BrowserSession] {
        guard TabTransfer.canSend(tab.url) else { return [] }
        return sessions.filter { TabTransfer.canSend(from: s.id, to: $0.id, incognito: incognito) }
            .map { ($0, label(of: $0)) }
            .sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
            .map(\.0)
    }

    /// Opens `tab`'s page in `target`'s front window and closes it here once
    /// `target` says it opened. No answer in 10 s: the tab stays.
    func send(_ tab: BrowserTab, from s: BrowserSession, to target: BrowserSession) {
        guard TabTransfer.canSend(tab.url), TabTransfer.canSend(from: s.id, to: target.id, incognito: false) else { return }
        let id = send(.open(tab.url), to: target)
        transfers.started(command: id, closing: .init(socketPath: s.socketPath, tabId: tab.id))
        // The extension brings its window forward; the browser comes with it.
        NSRunningApplication(processIdentifier: pid_t(target.browserPid))?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.transfers.gaveUp(command: id) }
    }

    private func answered(command: String, ok: Bool) {
        guard let source = transfers.answered(command: command, ok: ok) else { return }
        hub?.send(.close(source.tabId), to: source.socketPath)
    }

    /// Puts this app's copy of the Tabs extension where browsers load it from,
    /// when this app's is newer or none is there yet (see `ExtensionCopy`).
    func refreshExtension() {
        let folder = ExtensionCopy.folder
        if let bundled = ExtensionCopy.bundled() {
            do {
                try ExtensionCopy.refresh(from: bundled, to: folder)
                extensionError = nil
            } catch {
                extensionError = "Couldn't put the Tabs extension in its folder: \(error.localizedDescription)"
            }
        }
        extensionVersion = ExtensionCopy.version(of: folder)
    }

    /// Shows the extension's folder in Finder, ready to drag onto the browser's
    /// Extensions page.
    func showExtensionFolder() {
        refreshExtension()
        guard extensionVersion != nil else { return }
        NSWorkspace.shared.activateFileViewerSelecting([ExtensionCopy.folder])
    }

    /// A browser still running the extension from before betterlink updated is
    /// told to reload it, once. The extension reloads only if its own files
    /// really changed, so a copy loaded from somewhere else stays as it is.
    private func reloadOutdatedExtensions(_ sessions: [BrowserSession]) {
        for s in sessions where !askedToReload.contains(s.id)
            && ExtensionCopy.shouldReload(running: s.extensionVersion, folderVersion: extensionVersion, canReload: s.can(.reloadSelf)) {
            askedToReload.insert(s.id)
            hub?.send(.reloadSelf(), to: s.socketPath)
        }
    }

    /// Finds each new session's profile in the background: the extension's id
    /// in a profile folder's extension storage, then that folder's name in the
    /// browser's Local State. Retried at most every 5 s until found, for a
    /// minute, then every 30 s (`ProfileLocator.lookAgain`).
    /// The color comes from the profile's Preferences (a custom theme) or
    /// Local State (the frame color).
    private func lookUpProfiles(_ sessions: [BrowserSession]) {
        for s in sessions {
            // Known ones are read again at most every 30 s, on the next tab
            // change, so a name or color changed in the browser shows up.
            guard let instance = s.instance,
                  Date().timeIntervalSince(profileLookups[instance] ?? .distantPast)
                    > ProfileLocator.lookAgain(found: profiles[instance] != nil,
                                               lookingFor: Date().timeIntervalSince(profileFirstLookups[instance] ?? Date())),
                  let place = Self.profileFolder(of: s) else { continue }
            profileLookups[instance] = Date()
            if profileFirstLookups[instance] == nil { profileFirstLookups[instance] = Date() }
            DispatchQueue.global(qos: .utility).async {
                guard let (ref, name, color) = Self.readProfile(instance: instance, place.browser, place.root) else { return }
                DispatchQueue.main.async {
                    // Publish only a change: a re-read that finds the same
                    // profile must not redraw everything watching it.
                    if let old = self.profiles[instance], old.ref == ref, old.name == name, old.color == color { return }
                    self.profiles[instance] = (ref, name, color)
                }
            }
        }
    }

    func open(_ text: String, in s: BrowserSession, windowId: Int? = nil) {
        hub?.send(.open(Self.normalize(text), windowId: windowId), to: s.socketPath)
    }
    /// Sends any command to a browser; its id comes back for matching the ack.
    /// The tab actions built on this are in TabActions.swift.
    @discardableResult
    func send(_ cmd: Command, to s: BrowserSession) -> String {
        hub?.send(cmd, to: s.socketPath)
        return cmd.id
    }
    func activate(_ tab: BrowserTab, in s: BrowserSession) { hub?.send(.activate(tab.id), to: s.socketPath) }
    func close(_ tab: BrowserTab, in s: BrowserSession) { hub?.send(.close(tab.id), to: s.socketPath) }

    /// The host binary inside the running app (Contents/Helpers), or next to the
    /// executable for `swift run`.
    nonisolated static var hostPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/betterlink-tabhost")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("betterlink-tabhost").path
    }

    func state(_ b: Browser) -> HostRegistration.State {
        guard let folder = b.dataFolder else { return .notInstalled }
        return HostRegistration.state(dataFolder: folder, hostPath: Self.hostPath)
    }

    /// `betterlink tabs setup` wrote or removed a helper file from another process.
    func registrationChanged() { registrationVersion += 1 }

    func setRegistered(_ on: Bool, _ b: Browser) {
        guard let folder = b.dataFolder else { return }
        do {
            if on { try HostRegistration.install(dataFolder: folder, hostPath: Self.hostPath) }
            else { try HostRegistration.uninstall(dataFolder: folder) }
            registrationError = nil
        } catch {
            registrationError = "Couldn't update \(b.name): \(error.localizedDescription)"
        }
        registrationVersion += 1
    }

    static func normalize(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil { return s }
        if s.contains("."), !s.contains(" ") { return "https://" + s }
        return "https://www.google.com/search?q=" + (s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s)
    }
}

/// A tab's site icon, only when the browser handed it over inline (a data:
/// URL). betterlink makes no network requests, so a remote icon URL is never
/// fetched; SavedIcon shows a letter instead.
struct Favicon: View {
    let url: String
    var body: some View {
        Group {
            if let img = Self.inlineImage(url) { Image(nsImage: img).resizable() }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }

    /// Decoded icons by their data: URL. A row redraws whenever its tab changes,
    /// and decoding the same icon each time was the sidebar's largest cost with
    /// many tabs open. A miss is remembered too.
    private static var decoded: [String: NSImage?] = [:]

    static func inlineImage(_ url: String) -> NSImage? {
        guard url.hasPrefix("data:image/") else { return nil }
        if let hit = decoded[url] { return hit }
        var image: NSImage?
        if let comma = url.firstIndex(of: ","), url[..<comma].hasSuffix(";base64"),
           let data = Data(base64Encoded: String(url[url.index(after: comma)...])) {
            image = NSImage(data: data)
        }
        // Far more than one session shows; past it the table starts over.
        if decoded.count >= 800 { decoded.removeAll(keepingCapacity: true) }
        decoded[url] = .some(image)
        return image
    }
}
