import AppKit
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
    /// Browser profiles, by the extension's instance id (see ProfileLocator).
    @Published private(set) var profiles: [String: (ref: ProfileRef, name: String, color: UInt32?)] = [:]
    private var profileLookups: [String: Date] = [:]
    @Published private(set) var registrationError: String?
    /// Bumped after a register/unregister so the browser rows re-read their state.
    @Published private(set) var registrationVersion = 0
    private var hub: SyncHub?

    /// Starts listening the first time the Sidebar page opens or the sidebar
    /// turns on, so betterlink does no tab work for anyone who uses neither.
    func start() {
        guard hub == nil else { return }
        let hub = SyncHub(onLine: { path, m in
            // Two things saved links' held tabs need the moment the browser says
            // them: the tab an open made (its ack), and a tab closed on its own.
            if m.type == "ack", let id = m.id, let tab = m.tabId {
                DispatchQueue.main.async { SidebarHoldsModel.shared.opened(command: id, tab: tab) }
            } else if m.type == "event", m.kind == "tabRemoved", m.isWindowClosing != true, let tab = m.tabId {
                DispatchQueue.main.async { SidebarHoldsModel.shared.closed(tab: tab, socketPath: path) }
            }
        }, onChange: { [weak self] s in
            DispatchQueue.main.async {
                SidebarHoldsModel.shared.settle(s, links: SidebarLibraryModel.shared.library.allLinkIDs)
                self?.sessions = s; self?.lookUpProfiles(s)
            }
        })
        self.hub = hub
        hub.start()
    }

    /// The browser profile a session runs in, once known ("Claude", "Work").
    func profileName(_ s: BrowserSession) -> String? { s.instance.flatMap { profiles[$0]?.name } }
    /// Which browser profile a session runs in, once known.
    func profileRef(_ s: BrowserSession) -> ProfileRef? { s.instance.flatMap { profiles[$0]?.ref } }
    /// The color the browser paints this profile's window frame, when it has one.
    func profileColor(_ s: BrowserSession) -> UInt32? { s.instance.flatMap { profiles[$0]?.color } }

    /// Finds each new session's profile in the background: the extension's id
    /// in a profile folder's extension storage, then that folder's name in the
    /// browser's Local State. Retried at most every 5 s until found (the
    /// browser writes the storage a moment after the extension starts).
    /// The color comes from the profile's Preferences (a custom theme) or
    /// Local State (the frame color).
    private func lookUpProfiles(_ sessions: [BrowserSession]) {
        for s in sessions {
            // Unknown profiles retry every 5 s; known ones are read again at most
            // every 30 s, on the next tab change, so a name or color changed in
            // the browser shows up.
            guard let instance = s.instance,
                  Date().timeIntervalSince(profileLookups[instance] ?? .distantPast) > (profiles[instance] == nil ? 5 : 30),
                  let app = NSRunningApplication(processIdentifier: pid_t(s.browserPid)),
                  let browser = app.bundleIdentifier.flatMap({ Browser.known(bundleId: $0) }),
                  let folder = browser.dataFolder else { continue }
            profileLookups[instance] = Date()
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support").appendingPathComponent(folder)
            DispatchQueue.global(qos: .utility).async {
                guard let dir = ProfileLocator.directory(instance: instance, dataFolder: root) else { return }
                let state = FileManager.default.contents(atPath: root.appendingPathComponent("Local State").path)
                let name = state.flatMap { ProfileCatalog.parse(localStateJSON: $0, browser: browser.bundleId)
                    .profiles.first { $0.directory == dir }?.name } ?? dir
                let ref = ProfileRef(browser: browser.bundleId, directory: dir)
                // A custom color theme's own color first (it is what the frame
                // shows), else the frame color Chrome records for the profile.
                let prefs = FileManager.default.contents(atPath: root.appendingPathComponent(dir).appendingPathComponent("Preferences").path)
                let color = prefs.flatMap { ProfileCatalog.themeColor(preferencesJSON: $0) }
                    ?? state.flatMap { ProfileCatalog.frameColor(localStateJSON: $0, directory: dir) }
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
    static var hostPath: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/betterlink-tabhost")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        return Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("betterlink-tabhost").path
    }

    func state(_ b: Browser) -> HostRegistration.State {
        guard let folder = b.dataFolder else { return .notInstalled }
        return HostRegistration.state(dataFolder: folder, hostPath: Self.hostPath)
    }

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

    /// Decoded icons by their data: URL. Every row redraws on every tab event,
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
