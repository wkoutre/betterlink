import AppKit
import BetterlinkCore
import SwiftUI
import TabSyncCore

/// SwiftUI has its own `Tab` (macOS 15), so name the browser's explicitly.
typealias BrowserTab = TabSyncCore.Tab

/// Tabs (preview): every open tab in every connected browser, live, for the
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
    /// The version of the Tabs extension in the folder browsers load it from
    /// (`ExtensionCopy.folder`), or nil when nothing is there.
    @Published private(set) var extensionVersion: String?
    @Published private(set) var extensionError: String?
    /// Sessions already asked to reload their extension: each is asked once.
    private var askedToReload: Set<String> = []
    private var hub: SyncHub?

    /// Starts listening the first time the Tabs page opens or the sidebar
    /// turns on, so betterlink does no tab work for anyone who uses neither.
    func start() {
        guard hub == nil else { return }
        refreshExtension()
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
                self?.sessions = s; self?.lookUpProfiles(s); self?.reloadOutdatedExtensions(s)
            }
        })
        self.hub = hub
        hub.start()
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

struct TabsPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var tabs = TabsModel.shared
    @ObservedObject private var sidebar = SidebarController.shared
    var body: some View {
        PageForm {
            PageHeader(title: "Tabs",
                       subtitle: "Preview. The sidebar beside your browser window: its settings, Sidebar Profiles, and the browsers it connects to.")
            SidebarSettings(sidebar: sidebar)
            SidebarProfilesSection()
            SidebarImportSection()
            if tabs.sessions.isEmpty {
                DSSection {
                    Text("No browser connected yet. Set up a browser below, load the Tabs extension in it, then open the browser.")
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DSSection {
                ExtensionRow()
                ForEach(model.browsers.filter { $0.family == .chromium && $0.dataFolder != nil }) { b in
                    BrowserRegistrationRow(browser: b, version: tabs.registrationVersion)
                }
            } header: {
                Text("Browsers")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let err = tabs.registrationError ?? tabs.extensionError {
                        Text(err).foregroundStyle(DS.Palette.danger)
                    }
                    Text("Set Up writes one file into the browser's NativeMessagingHosts folder so it can start betterlink's tab helper. Then add the Tabs extension, once per browser profile: open chrome://extensions, turn on Developer mode, and drag the extension's folder from Finder onto the page. Leave Developer mode on, or the browser turns the extension off.")
                        .foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(DS.TextStyle.caption)
            }
        }
        .onAppear { tabs.start() }
    }
}

/// A tab's site icon, only when the browser handed it over inline (a data:
/// URL). betterlink makes no network requests, so a remote icon URL shows the
/// globe instead of being fetched.
struct Favicon: View {
    let url: String
    var body: some View {
        Group {
            if let img = Self.inlineImage(url) {
                Image(nsImage: img).resizable()
            } else {
                Image(systemName: "globe").resizable().foregroundStyle(DS.Palette.textTertiary)
            }
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

/// The sidebar that binds to the front browser window.
private struct SidebarSettings: View {
    @ObservedObject var sidebar: SidebarController
    @EnvironmentObject var model: AppModel

    /// Installed browsers the sidebar can follow: the Chromium family (tabs
    /// through the extension) and Safari.
    private var attachable: [Browser] {
        model.browsers.filter { $0.family == .chromium || $0.bundleId == "com.apple.Safari" }
    }

    var body: some View {
        DSSection {
            Toggle(isOn: $sidebar.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show the sidebar")
                    Text("Sits against the front browser window's edge and moves with it.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                }
            }
            if sidebar.enabled && sidebar.trusted {
                LabeledContent("Now") {
                    Text(sidebar.collapsed ? "Hidden. Press \(sidebar.shortcut.display) in the browser to show it."
                         : sidebar.target.map { "On \($0.appName)" } ?? "Waiting for one of the browsers below to be in front")
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
            if sidebar.enabled && !sidebar.trusted {
                HStack {
                    Text("betterlink needs Accessibility access to follow your browser windows.")
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Allow…") { sidebar.requestTrust() }
                }
            }
            LabeledContent("Side") {
                Picker("Side", selection: $sidebar.side) {
                    Text("Left").tag(SidebarSide.left)
                    Text("Right").tag(SidebarSide.right)
                    Text("Whichever has room").tag(SidebarSide.auto)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
            }
            VStack(alignment: .leading, spacing: DS.Space.space2) {
                Text("Attach to")
                Text("The sidebar follows these browsers' windows.")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(attachable) { b in
                    Toggle(b.name, isOn: Binding(
                        get: { sidebar.attachTo.contains(b.bundleId) },
                        set: { on in if on { sidebar.attachTo.insert(b.bundleId) } else { sidebar.attachTo.remove(b.bundleId) } }))
                }
            }
            Toggle(isOn: $sidebar.takeOverTabs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take over the browser's tabs")
                    Text("Collapses the browser's own tab strip to vertical tabs (Chrome: View › Collapse Vertical Tabs). The sidebar sits beside that column. Turning this off leaves the browser's tabs as they are.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LabeledContent("Show or hide") {
                HStack {
                    ShortcutRecorder(shortcut: $sidebar.shortcut)
                    if sidebar.shortcut != .sidebarDefault {
                        Button("Reset") { sidebar.shortcut = .sidebarDefault }
                    }
                }
                if let problem = sidebar.hotKeyProblem {
                    Text(problem).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.danger)
                }
            }
            LabeledContent("Width") {
                HStack {
                    Slider(value: $sidebar.width, in: 200...440, step: 10).frame(maxWidth: 220)
                    Text("\(Int(sidebar.width)) pt").monospacedDigit().foregroundStyle(DS.Palette.textSecondary)
                }
            }
        } header: {
            Text("Sidebar")
        }
    }
}

/// The Tabs extension on this Mac: its version, and its folder in Finder for
/// dragging onto a browser's Extensions page.
private struct ExtensionRow: View {
    @ObservedObject private var tabs = TabsModel.shared

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Tabs extension")
                Group {
                    if let version = tabs.extensionVersion {
                        Text("Version \(version). Updates with betterlink.")
                    } else {
                        Text("Not in this build. Load browser-extension from the source folder.")
                    }
                }
                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
            }
            Spacer()
            Button("Show in Finder") { tabs.showExtensionFolder() }
                .disabled(tabs.extensionVersion == nil)
        }
    }
}

private struct BrowserRegistrationRow: View {
    @ObservedObject private var tabs = TabsModel.shared
    let browser: Browser
    let version: Int

    var body: some View {
        let state = tabs.state(browser)
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(browser.name)
                switch state {
                case .installed: Text("Set up").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.success)
                case .notInstalled: Text("Not set up").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                case .stale: Text("Set up for an older betterlink. Set up again.").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                }
            }
            Spacer()
            if state == .installed {
                Button("Remove") { tabs.setRegistered(false, browser) }
            } else {
                Button(state == .notInstalled ? "Set Up" : "Set Up Again") { tabs.setRegistered(true, browser) }
            }
        }
    }
}

/// Click, then press the new shortcut. Escape cancels. It needs Control and
/// must not be one of the browser's own (Shortcut.isValid).
private struct ShortcutRecorder: View {
    @Binding var shortcut: Shortcut
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button(recording ? "Press a shortcut…" : shortcut.display) { recording ? stop() : start() }
                .monospaced()
                .accessibilityLabel(recording ? "Recording a shortcut" : "Shortcut \(shortcut.display). Click to change.")
            if let hint { Text(hint).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary) }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        hint = "Use Control with a key (and Option or Shift if you like). Esc cancels."
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil } // Escape
            var m: UInt32 = 0
            let f = e.modifierFlags
            if f.contains(.command) { m |= Shortcut.command }
            if f.contains(.shift) { m |= Shortcut.shift }
            if f.contains(.option) { m |= Shortcut.option }
            if f.contains(.control) { m |= Shortcut.control }
            let s = Shortcut(keyCode: UInt32(e.keyCode), modifiers: m,
                             key: Shortcut.label(keyCode: UInt32(e.keyCode), typed: e.charactersIgnoringModifiers ?? ""))
            guard s.isValid else {
                hint = s.isBrowserShortcut ? "That one is the browser's own. Pick another."
                    : "Add Control: without it, the shortcut would take one of the browser's or type a character."
                return nil
            }
            shortcut = s
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        hint = nil
    }
}

/// The Sidebar Profiles: each has its own Favorites and folders and is shown
/// for the browser profiles linked to it (pick one from the ⚙ at the top of the sidebar).
private struct SidebarProfilesSection: View {
    @ObservedObject private var lib = SidebarLibraryModel.shared
    @ObservedObject private var tabs = TabsModel.shared
    /// Deleting a Sidebar Profile asks first: it takes its Favorites and folders with it (review F6).
    @State private var confirmDelete: SidebarProfile?

    var body: some View {
        DSSection {
            ForEach(lib.library.profiles) { sp in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("Name", text: Binding(get: { sp.name },
                                                        set: { n in
                                                            // A blank name is not saved (review F4).
                                                            guard !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                                                            lib.change(profile: sp.id) { $0.name = n }
                                                        }))
                            .textFieldStyle(.plain)
                        Text(links(sp)).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    }
                    Spacer()
                    Text("\(sp.favorites.count) favorites · \(sp.allLinks.count - sp.favorites.count) saved links")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    if lib.library.profiles.count > 1 {
                        Button("Delete") { confirmDelete = sp }
                    }
                }
            }
            if let problem = lib.problem { Text(problem).foregroundStyle(DS.Palette.danger) }
            Text("Pick which Sidebar Profile a browser profile shows from the ⚙ at the top of the sidebar. Saved in sidebar.json in the settings folder.")
                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Sidebar Profiles")
        }
        .confirmationDialog("Delete the Sidebar Profile \"\(confirmDelete?.name ?? "")\"?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete it and its \(confirmDelete?.allLinks.count ?? 0) saved links", role: .destructive) {
                if let sp = confirmDelete { lib.change { $0.removeProfile(sp.id) } }
                confirmDelete = nil
            }
        }
    }

    private func links(_ sp: SidebarProfile) -> String {
        guard !sp.browserProfiles.isEmpty else { return "Every browser profile not linked elsewhere" }
        let known = Dictionary(tabs.profiles.values.map { ($0.ref, $0.name) }, uniquingKeysWith: { a, _ in a })
        return sp.browserProfiles.map { ref in
            let browser = Browser.known(bundleId: ref.browser)?.name ?? ref.browser
            return "\(browser) · \(known[ref] ?? ref.directory)"
        }.joined(separator: ", ")
    }
}
