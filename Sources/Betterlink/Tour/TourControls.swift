import AppKit
import BetterlinkCore
import CoreServices
import SwiftUI
import TabSyncCore

// What a step lets a person do, and what it shows as done. Each control calls
// the same method the window's own page calls, so the tour can never do
// something the pages can't, or do it differently.
//
// TourControl and TourProbe are generated from Tour/tour.json. The switches
// here have no default on purpose: a control or status named there and not
// drawn here stops the build.

/// The card under a step's text: its status, and the control.
struct TourControlCard: View {
    let step: TourStep

    var body: some View {
        if let control = step.control {
            TourControlView(control: control, probe: step.status)
                .padding(.horizontal, DS.Space.space4)
                .padding(.vertical, DS.Space.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous).fill(DS.Palette.panel))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous)
                    .strokeBorder(DS.Palette.borderSubtle, lineWidth: 1))
                .cardShadow()
        }
    }
}

struct TourControlView: View {
    let control: TourControl
    let probe: TourProbe?

    @EnvironmentObject private var model: AppModel
    @ObservedObject private var sidebar = SidebarController.shared
    @ObservedObject private var tabs = TabsModel.shared
    @ObservedObject private var sync = SyncController.shared
    @ObservedObject private var updater = Updater.shared
    @StateObject private var dia = DiaAutomation()
    @State private var editingRules = false
    @State private var editingKeys = false
    @State private var editingProfiles = false
    @State private var trusted = WindowTracker.isTrusted
    @State private var copied: String?

    var body: some View {
        content
            .onAppear(perform: refresh)
            // Coming back from System Settings or a browser: look again.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
            .sheet(isPresented: $editingRules) {
                RulesEditor(initial: model.rules) { editingRules = false }.environmentObject(model)
            }
            .sheet(isPresented: $editingKeys) {
                KeysEditor(initial: model.modifierRules) { editingKeys = false }.environmentObject(model)
            }
            .sheet(isPresented: $editingProfiles) {
                ProfilesEditor(initial: model.catalog.profiles.filter { !$0.directory.isEmpty }) { editingProfiles = false }
                    .environmentObject(model)
            }
    }

    private func refresh() {
        model.refreshPermissions()
        model.refreshCommandInstall()
        trusted = WindowTracker.isTrusted
        if control == .askDiaAutomation { dia.check() }
        // Only the steps about the sidebar's browsers listen for them.
        if control == .showExtension { tabs.start() }
    }

    // MARK: The row every control is drawn as

    /// A line saying where things stand, its status, and the control on the right.
    private func row<Action: View>(_ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: DS.Space.space3) {
            VStack(alignment: .leading, spacing: DS.Space.space1) {
                if let probe { badge(probe) }
                Text(text)
                    .foregroundStyle(DS.Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.space2)
            action()
        }
    }

    private func toggle(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn).labelsHidden().fixedSize().accessibilityLabel(label)
    }

    private func copyButton(_ title: String, _ text: String) -> some View {
        Button(copied == text ? "Copied" : title) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == text { copied = nil } }
        }
    }

    // MARK: Controls

    @ViewBuilder private var content: some View {
        switch control {
        case .makeDefaultBrowser: defaultBrowser
        case .browserData: browserData
        case .fallbackPicker: fallbackPicker
        case .firstRule: firstRule
        case .editKeys: editKeys
        case .linkToast: linkToast
        case .showLog:
            row("Show the Log page in this window.") { toggle("Show the Log page", $model.showLog) }
        case .menuBarIcon:
            row("Show betterlink in the menu bar.") { toggle("Show betterlink in the menu bar", $model.showsMenuBarIcon) }
        case .openAtLogin:
            row("Open betterlink when you log in.") {
                toggle("Open at login", Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
            }
        case .sidebarBrowsers: sidebarBrowsers
        case .showExtension: showExtension
        case .allowAccessibility: allowAccessibility
        case .showSidebar:
            row("Show a sidebar beside every window of an attached browser.") { toggle("Show the sidebar", $sidebar.enabled) }
        case .chooseSyncFolder: chooseSyncFolder
        case .installCommand: installCommand
        case .askDiaAutomation: askDiaAutomation
        case .createConfig:
            row(model.configStatus == .absent ? "There is no config.ts yet. Creating one changes nothing until you edit it."
                                              : "config.ts opens in your editor.") {
                Button(model.configStatus == .absent ? "Create config.ts" : "Open in Editor") { model.editConfig() }
            }
        case .automaticUpdates:
            row(updater.isAvailable ? "Check for updates once a day."
                                    : "This build has no update key, so it doesn't check for updates. Release builds do.") {
                toggle("Check for updates automatically", $updater.automaticallyChecks).disabled(!updater.isAvailable)
            }
        }
    }

    private var defaultBrowser: some View {
        row(model.isDefaultBrowser ? "Links you click in other apps come to betterlink first."
                                   : "macOS asks you to confirm. Until then, your current browser keeps opening links.") {
            if !model.isDefaultBrowser {
                Button("Make Default Browser") { model.makeDefaultBrowser() }.buttonStyle(.dsPrimary)
            }
        }
    }

    /// Browsers whose profile list betterlink can't read, though it is there.
    private var unreadable: [Browser] {
        model.browsers.filter { b in
            guard let access = model.browserAccess[b.bundleId] else { return false }
            return access != .readable && access != .missing
        }
    }

    private var browserData: some View {
        let count = model.catalog.profiles.filter { !$0.directory.isEmpty }.count
        let found = count == 0 ? "No profiles found yet." : "Found \(count) profile\(count == 1 ? "" : "s")."
        let blocked = unreadable.isEmpty ? "" : " Can't read \(unreadable.map(\.name).joined(separator: ", "))."
        return row(found + blocked) {
            if !unreadable.isEmpty { Button("Open Privacy Settings") { model.openFullDiskAccessSettings() } }
            Button("Edit Profiles…") { editingProfiles = true }.disabled(model.rulesError != nil)
        }
    }

    private var fallbackPicker: some View {
        row("Everything else opens in") { ProfileMenu(selection: $model.fallback, width: 220) }
    }

    private var firstRule: some View {
        let n = model.rules.count
        return row(n == 0 ? "No rules yet." : "You have \(n) rule\(n == 1 ? "" : "s").") {
            Button(n == 0 ? "Add a Rule…" : "Edit Rules…") { editingRules = true }
                .buttonStyle(.dsPrimary)
                .disabled(model.rulesError != nil)
        }
    }

    private var editKeys: some View {
        let n = model.modifierRules.count
        return row(n == 0 ? "No modifier keys yet." : "\(n) key combination\(n == 1 ? "" : "s") set.") {
            Button(n == 0 ? "Add Keys…" : "Edit Keys…") { editingKeys = true }.disabled(model.rulesError != nil)
        }
    }

    private var linkToast: some View {
        row("Show a toast when a rule picks the profile.") {
            Button("Preview") { model.previewLinkToast() }.disabled(!model.showsLinkToast)
            toggle("Show a toast when a rule picks the profile", $model.showsLinkToast)
        }
    }

    private var sidebarBrowsers: some View {
        VStack(alignment: .leading, spacing: DS.Space.space2) {
            ForEach(model.browsers.filter(\.hostsSidebar)) { b in
                let state = tabs.state(b)
                HStack(spacing: DS.Space.space3) {
                    Text(b.name)
                    switch state {
                    case .installed: StatusBadge(text: "Set up", kind: .success, symbol: "checkmark")
                    case .notInstalled: StatusBadge(text: "Not set up", kind: .neutral)
                    case .stale: StatusBadge(text: "Points elsewhere", kind: .warning)
                    }
                    Spacer(minLength: 0)
                    switch state {
                    case .installed: Button("Uninstall") { tabs.setRegistered(false, b) }.buttonStyle(.dsGhost)
                    case .notInstalled: Button("Set Up") { tabs.setRegistered(true, b) }
                    case .stale: Button("Set Up Again") { tabs.setRegistered(true, b) }
                    }
                }
                // As on the Sidebar page: which profiles have the extension connected.
                let connections = tabs.connections(b)
                if let line = connections.line(browser: b.name, helperSetUp: state == .installed) {
                    Text(line)
                        .font(DS.TextStyle.caption)
                        .foregroundStyle(connections.state == .outdated ? DS.Palette.warning : DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem = tabs.registrationError {
                Text(problem).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.danger)
            }
        }
        // Re-reads each browser's state after a change.
        .id(tabs.registrationVersion)
    }

    private var showExtension: some View {
        let connected = Array(Set(tabs.sessions.map(\.browser))).sorted()
        let text = connected.isEmpty
            ? (tabs.extensionVersion == nil ? "This build has no Tabs extension in it." : "No browser has the extension running yet.")
            : "Running in \(connected.joined(separator: ", "))."
        return row(text) {
            copyButton("Copy chrome://extensions", "chrome://extensions")
            Button("Show in Finder") { tabs.showExtensionFolder() }
                .buttonStyle(.dsPrimary)
                .disabled(tabs.extensionVersion == nil)
        }
    }

    private var allowAccessibility: some View {
        row(trusted ? "betterlink can follow your browser windows."
                    : "System Settings opens at Accessibility. Turn betterlink on in the list, then come back.") {
            if !trusted {
                Button("Open Accessibility Settings…") {
                    // The request puts betterlink in the list (and shows
                    // macOS's own alert, the first time only); opening the
                    // pane is what the button says, every time.
                    sidebar.requestTrust()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }.buttonStyle(.dsPrimary)
            }
        }
        // macOS doesn't say when it is granted, so look twice a second, and
        // only while this step is on screen and still waiting.
        .task {
            while !trusted && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                trusted = WindowTracker.isTrusted
            }
        }
    }

    private var chooseSyncFolder: some View {
        row(sync.folder.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "Sync is off on this Mac.") {
            if sync.folder != nil { Button("Turn Off") { sync.turnOff() } }
            Button(sync.folder == nil ? "Choose Folder…" : "Change…") { sync.chooseFolderWithPanel() }
        }
    }

    private var installCommand: some View {
        row(model.commandLink.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
            copyButton("Copy Prompt", model.agentPrompt)
            switch model.commandInstall {
            case .installed: EmptyView()
            case .notInstalled: Button("Install Command") { model.installCommand() }.buttonStyle(.dsPrimary)
            case .pointsElsewhere: Button("Reinstall") { model.installCommand() }.buttonStyle(.dsPrimary)
            case .blocked: EmptyView()
            }
        }
    }

    private var askDiaAutomation: some View {
        row(dia.state.explanation) {
            switch dia.state {
            case .unknown, .allowed: EmptyView()
            case .notRunning: Button("Check Again") { dia.check() }
            case .notAsked: Button("Ask macOS Now") { dia.check(ask: true) }.buttonStyle(.dsPrimary)
            case .denied: Button("Open Automation Settings") { DiaAutomation.openSettings() }
            }
        }
    }

    // MARK: Statuses

    private func badge(_ probe: TourProbe) -> StatusBadge {
        func on(_ isOn: Bool, _ yes: String = "On", _ no: String = "Off") -> StatusBadge {
            isOn ? StatusBadge(text: yes, kind: .success, symbol: "checkmark") : StatusBadge(text: no, kind: .neutral)
        }
        switch probe {
        case .defaultBrowser:
            return model.isDefaultBrowser ? StatusBadge(text: "Default browser", kind: .success, symbol: "checkmark")
                                          : StatusBadge(text: "Not set", kind: .warning)
        case .browserData:
            if !unreadable.isEmpty { return StatusBadge(text: "Not allowed", kind: .warning) }
            return on(model.browserAccess.values.contains(.readable), "Allowed", "Optional")
        case .openAtLogin:
            return on(model.opensAtLogin)
        case .tabsHelper:
            return on(model.browsers.contains { tabs.state($0) == .installed }, "Set up", "Not set up")
        case .tabsExtension:
            return on(!tabs.sessions.isEmpty, "Connected", "Not connected")
        case .accessibility:
            return on(trusted, "Allowed", "Not allowed yet")
        case .sidebar:
            return on(sidebar.enabled)
        case .syncFolder:
            return on(sync.folder != nil)
        case .command:
            switch model.commandInstall {
            case .installed: return StatusBadge(text: "Installed", kind: .success, symbol: "checkmark")
            case .notInstalled: return StatusBadge(text: "Not installed", kind: .neutral)
            case .pointsElsewhere: return StatusBadge(text: "Points elsewhere", kind: .warning)
            case .blocked: return StatusBadge(text: "Name taken", kind: .warning)
            }
        case .automationDia:
            switch dia.state {
            case .allowed: return StatusBadge(text: "Allowed", kind: .success, symbol: "checkmark")
            case .denied: return StatusBadge(text: "Not allowed", kind: .warning)
            case .notAsked: return StatusBadge(text: "Not asked yet", kind: .neutral)
            case .notRunning, .unknown: return StatusBadge(text: "Open Dia to check", kind: .neutral)
            }
        case .config:
            switch model.configStatus {
            case .absent: return StatusBadge(text: "Not created", kind: .neutral)
            case .loading: return StatusBadge(text: "Loading", kind: .neutral)
            case .loaded: return StatusBadge(text: "Running", kind: .success, symbol: "checkmark")
            case .failed: return StatusBadge(text: "Not loaded", kind: .warning)
            }
        }
    }
}

private let diaBundleId = "company.thebrowser.dia"

/// Whether macOS lets betterlink control Dia (Automation), which switching
/// Dia's spaces needs. macOS only answers while Dia is running, and the
/// question can block, so it is asked off the main thread.
@MainActor
final class DiaAutomation: ObservableObject {
    enum State: Equatable {
        case unknown, notRunning, allowed, notAsked, denied

        var explanation: String {
            switch self {
            case .unknown: "Checking whether betterlink may switch Dia's spaces."
            case .notRunning: "Open Dia, then check again: macOS only answers while Dia is running."
            case .allowed: "betterlink may switch Dia's spaces."
            case .notAsked: "macOS hasn't asked yet. It asks now, or the first time a link goes to Dia."
            case .denied: "macOS was told no. Turn on Dia under betterlink in Automation."
            }
        }
    }

    @Published private(set) var state: State = .unknown

    /// `ask`: let macOS show its question if it hasn't yet.
    func check(ask: Bool = false) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: diaBundleId).isEmpty else {
            state = .notRunning
            return
        }
        Task.detached(priority: .userInitiated) {
            let status = Self.permission(ask: ask)
            await MainActor.run {
                switch Int(status) {
                case 0: self.state = .allowed
                case -1744: self.state = .notAsked   // errAEEventWouldRequireUserConsent
                case -1743: self.state = .denied     // errAEEventNotPermitted
                case -600: self.state = .notRunning  // procNotFound
                default: self.state = .unknown
                }
            }
        }
    }

    private nonisolated static func permission(ask: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: diaBundleId)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
