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
    @Published private(set) var registrationError: String?
    /// Bumped after a register/unregister so the browser rows re-read their state.
    @Published private(set) var registrationVersion = 0
    private var hub: SyncHub?

    /// Starts listening the first time the Tabs page opens, so betterlink does
    /// no tab work at all for anyone who never opens it.
    func start() {
        guard hub == nil else { return }
        let hub = SyncHub(onChange: { [weak self] s in
            DispatchQueue.main.async { self?.sessions = s }
        })
        self.hub = hub
        hub.start()
    }

    func open(_ text: String) {
        guard let s = sessions.first else { return }
        hub?.send(.open(Self.normalize(text)), to: s.socketPath)
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
    @State private var newURL = ""

    var body: some View {
        PageForm {
            PageHeader(title: "Tabs",
                       subtitle: "Preview. Every open tab in your browsers, live. Click a tab to switch to it, ✕ to close it.")
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
                            Text("\(session.browser) · Window \(i + 1)")
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

private struct Favicon: View {
    let url: String
    var body: some View {
        Group {
            if let u = URL(string: url), ["http", "https"].contains(u.scheme ?? "") {
                AsyncImage(url: u) { $0.resizable() } placeholder: { globe }
            } else {
                globe
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
    private var globe: some View { Image(systemName: "globe").resizable().foregroundStyle(DS.Palette.textTertiary) }
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
