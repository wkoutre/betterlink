import AppKit
import BetterlinkCore
import SwiftUI
import TabSyncCore

/// SwiftUI has its own `Tab` (macOS 15), so name the browser's explicitly.
typealias BrowserTab = TabSyncCore.Tab

/// Tabs (preview): every open tab in every connected browser, live. The
/// browser pushes each change through the Tabs extension and
/// betterlink-tabhost the instant it happens; nothing here polls. Clicking a
/// tab focuses it in the browser, ✕ closes it, and the field opens a new one.
@MainActor
final class TabsModel: ObservableObject {
    static let shared = TabsModel()

    @Published private(set) var sessions: [BrowserSession] = []
    /// Browser profile names, by the extension's instance id (see ProfileLocator).
    @Published private(set) var profileNames: [String: String] = [:]
    private var profileLookups: [String: Date] = [:]
    @Published private(set) var registrationError: String?
    /// Bumped after a register/unregister so the browser rows re-read their state.
    @Published private(set) var registrationVersion = 0
    private var hub: SyncHub?

    /// Starts listening the first time the Tabs page opens, so betterlink does
    /// no tab work at all for anyone who never opens it.
    func start() {
        guard hub == nil else { return }
        let hub = SyncHub(onChange: { [weak self] s in
            DispatchQueue.main.async { self?.sessions = s; self?.lookUpProfiles(s) }
        })
        self.hub = hub
        hub.start()
    }

    /// The browser profile a session runs in, once known ("Claude", "Work").
    func profileName(_ s: BrowserSession) -> String? { s.instance.flatMap { profileNames[$0] } }

    /// Finds each new session's profile in the background: the extension's id
    /// in a profile folder's extension storage, then that folder's name in the
    /// browser's Local State. Retried at most every 5 s until found (the
    /// browser writes the storage a moment after the extension starts).
    private func lookUpProfiles(_ sessions: [BrowserSession]) {
        for s in sessions {
            guard let instance = s.instance, profileNames[instance] == nil,
                  Date().timeIntervalSince(profileLookups[instance] ?? .distantPast) > 5,
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
                DispatchQueue.main.async { self.profileNames[instance] = name }
            }
        }
    }

    func open(_ text: String, in session: BrowserSession? = nil, windowId: Int? = nil) {
        guard let s = session ?? sessions.first else { return }
        hub?.send(.open(Self.normalize(text), windowId: windowId), to: s.socketPath)
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
    @State private var newURL = ""

    var body: some View {
        PageForm {
            PageHeader(title: "Tabs",
                       subtitle: "Preview. Every open tab in your browsers, live. Click a tab to switch to it, ✕ to close it.")
            SidebarSettings(sidebar: sidebar)
            DSSection {
                HStack(spacing: DS.Space.space2) {
                    DSTextField(label: "Open a tab", text: $newURL, prompt: "Open a link or search")
                        .onSubmit {
                            guard !newURL.isEmpty else { return }
                            tabs.open(newURL)
                            newURL = ""
                        }
                    Button("Open") { tabs.open(newURL); newURL = "" }
                        .disabled(newURL.isEmpty || tabs.sessions.isEmpty)
                }
            } footer: {
                LatencyFooter(sessions: tabs.sessions)
            }

            if tabs.sessions.isEmpty {
                DSSection {
                    Text("No browser connected yet. Set up a browser below, load the Tabs extension in it, then open the browser.")
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(tabs.sessions) { session in
                ForEach(Array(session.store.orderedWindows.enumerated()), id: \.element.id) { i, entry in
                    DSSection {
                        ForEach(entry.tabs) { tab in TabRow(tab: tab, session: session) }
                    } header: {
                        HStack {
                            Text("\(session.browser)\(tabs.profileName(session).map { " (\($0))" } ?? "") · Window \(i + 1)")
                            if entry.window.focused {
                                Circle().fill(DS.Palette.success).frame(width: 6, height: 6).accessibilityLabel("Focused")
                            }
                            Spacer()
                            Text("\(entry.tabs.count) tabs").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        }
                    }
                }
            }

            DSSection {
                ForEach(model.browsers.filter { $0.family == .chromium && $0.dataFolder != nil }) { b in
                    BrowserRegistrationRow(browser: b, version: tabs.registrationVersion)
                }
            } header: {
                Text("Browsers")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let err = tabs.registrationError {
                        Text(err).foregroundStyle(DS.Palette.danger)
                    }
                    Text("Set Up writes one file into the browser's NativeMessagingHosts folder so it can start betterlink's tab helper. Then load the Tabs extension in that browser (chrome://extensions › Developer mode › Load unpacked › browser-extension).")
                        .foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(DS.TextStyle.caption)
            }
        }
        .onAppear { tabs.start() }
    }
}

private struct TabRow: View {
    @ObservedObject private var tabs = TabsModel.shared
    let tab: BrowserTab
    let session: BrowserSession
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.space3) {
            Favicon(url: tab.favIconUrl)
            VStack(alignment: .leading, spacing: 1) {
                Text(tab.title.isEmpty ? tab.url : tab.title)
                    .lineLimit(1)
                    .fontWeight(tab.active ? .semibold : .regular)
                    .foregroundStyle(DS.Palette.text)
                Text(URL(string: tab.url)?.host ?? tab.url)
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if tab.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(DS.Palette.textTertiary) }
            if tab.audible { Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(DS.Palette.textTertiary) }
            Button { tabs.close(tab, in: session) } label: { Image(systemName: "xmark") }
                .buttonStyle(.dsGhost)
                .opacity(hovering ? 1 : 0)
                .accessibilityLabel("Close \(tab.title)")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { tabs.activate(tab, in: session) }
        .accessibilityAddTraits(tab.active ? [.isButton, .isSelected] : .isButton)
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

    static func inlineImage(_ url: String) -> NSImage? {
        guard url.hasPrefix("data:image/"), let comma = url.firstIndex(of: ","),
              url[..<comma].hasSuffix(";base64"),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
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

private struct LatencyFooter: View {
    let sessions: [BrowserSession]
    var body: some View {
        HStack(spacing: DS.Space.space3) {
            Text(sessions.isEmpty ? "Waiting for a browser" : "\(sessions.reduce(0) { $0 + $1.store.tabCount }) tabs in \(sessions.count) browser\(sessions.count == 1 ? "" : "s")")
            Spacer()
            if let l = sessions.compactMap(\.lastEventLatencyMs).last { Text(String(format: "last change %.1f ms", l)) }
            if let r = sessions.compactMap(\.lastCommandRoundTripMs).last { Text(String(format: "last command %.1f ms", r)) }
        }
        .font(DS.TextStyle.caption.monospacedDigit())
        .foregroundStyle(DS.Palette.textTertiary)
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
