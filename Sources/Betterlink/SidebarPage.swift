import AppKit
import BetterlinkCore
import SwiftUI
import TabSyncCore

/// The sidebar's settings: the browsers it attaches to, the sidebar itself,
/// and imports. Sidebar Profiles are managed from the cog in the sidebar.
struct SidebarPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var tabs = TabsModel.shared
    @ObservedObject private var sidebar = SidebarController.shared
    @ObservedObject private var lib = SidebarLibraryModel.shared

    var body: some View {
        PageForm {
            PageHeader(title: "Sidebar",
                       subtitle: "A sidebar for your browser: Favorites, folders and this window's tabs.")
            if let problem = lib.problem { Banner(text: problem, style: .error) }
            browsers
            settings
            options
            SidebarImportSection()
        }
        .onAppear { tabs.start() }
    }

    private var browsers: some View {
        DSSection {
            ExtensionRow()
            ForEach(model.browsers.filter(\.hostsSidebar)) { b in
                SidebarBrowserRow(browser: b, version: tabs.registrationVersion)
            }
        } header: {
            Text("Browsers")
        } footer: {
            VStack(alignment: .leading, spacing: DS.Space.space1) {
                if let err = tabs.registrationError ?? tabs.extensionError {
                    Text(err).foregroundStyle(DS.Palette.danger)
                }
                Text("Set Up writes one file into the browser's NativeMessagingHosts folder so it can start betterlink's tab helper. Then add the Tabs extension, once per Browser Profile: open chrome://extensions, turn on Developer mode, and drag the extension's folder from Finder onto the page. Leave Developer mode on, or the browser turns the extension off. For Incognito windows, also turn on Allow in Incognito for it.")
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(DS.TextStyle.caption)
        }
    }

    private var settings: some View {
        DSSection {
            Toggle(isOn: $sidebar.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show the sidebar")
                    Text("Sits against the front browser window's edge and moves with it. Drag the edge between them to resize it.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
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
        } header: {
            Text("Sidebar")
        }
    }

    private var options: some View {
        DSSection("Options") {
            Toggle(isOn: $sidebar.takeOverTabs) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Take over the browser's tabs")
                    Text("Hides the browser's own tab strip.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                }
            }
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

/// One browser: whether its tab helper is set up, and whether the sidebar
/// attaches to it.
private struct SidebarBrowserRow: View {
    @ObservedObject private var tabs = TabsModel.shared
    @ObservedObject private var sidebar = SidebarController.shared
    let browser: Browser
    /// Re-reads the state after a change.
    let version: Int

    var body: some View {
        let state = tabs.state(browser)
        HStack(spacing: DS.Space.space3) {
            Text(browser.name)
            switch state {
            case .installed: StatusBadge(text: "Set up", kind: .success, symbol: "checkmark")
            case .notInstalled: StatusBadge(text: "Not set up", kind: .neutral)
            case .stale: StatusBadge(text: "Points elsewhere", kind: .warning)
            }
            Spacer(minLength: 0)
            switch state {
            case .installed: Button("Uninstall") { tabs.setRegistered(false, browser) }.buttonStyle(.dsGhost)
            case .notInstalled: Button("Set Up") { tabs.setRegistered(true, browser) }
            case .stale: Button("Set Up Again") { tabs.setRegistered(true, browser) }
            }
            Toggle("Attach to \(browser.name)", isOn: Binding(
                get: { sidebar.attachTo.contains(browser.bundleId) },
                set: { on in if on { sidebar.attachTo.insert(browser.bundleId) } else { sidebar.attachTo.remove(browser.bundleId) } }))
                .labelsHidden()
                .help("The sidebar attaches to \(browser.name)")
                .accessibilityLabel("Attach to \(browser.name)")
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
