import AppKit
import BetterlinkCore
import SwiftUI
import TabSyncCore

/// What the Sidebar page shows, top to bottom. The Sidebar section and its
/// switch come first. While the sidebar is off the switch is all there is:
/// nothing else on the page does anything until it is on.
struct SidebarPagePlan: Equatable {
    enum Section: Hashable { case sidebar, browsers, options, imports }
    /// A row of the Sidebar section.
    enum Row: Hashable { case show, windowsWarning, cornersNote, accessibility, side, shortcut }

    let sections: [Section]
    let rows: [Row]

    init(enabled: Bool, canTellWindowsApart: Bool = true, readsWindowCorners: Bool = true, trusted: Bool = true) {
        guard enabled else {
            sections = [.sidebar]
            rows = [.show]
            return
        }
        sections = [.sidebar, .browsers, .options, .imports]
        var rows: [Row] = [.show]
        if !canTellWindowsApart { rows.append(.windowsWarning) }
        if !readsWindowCorners { rows.append(.cornersNote) }
        if !trusted { rows.append(.accessibility) }
        self.rows = rows + [.side, .shortcut]
    }
}

/// The sidebar's settings: the sidebar itself, the browsers it attaches to,
/// and imports. Sidebar Profiles are managed from the cog in the sidebar.
struct SidebarPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var tabs = TabsModel.shared
    @ObservedObject private var sidebar = SidebarController.shared
    @ObservedObject private var lib = SidebarLibraryModel.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var plan: SidebarPagePlan {
        SidebarPagePlan(enabled: sidebar.enabled, canTellWindowsApart: sidebar.canTellWindowsApart,
                        readsWindowCorners: sidebar.readsWindowCorners, trusted: sidebar.trusted)
    }

    var body: some View {
        let plan = self.plan
        PageForm {
            PageHeader(title: "Sidebar",
                       subtitle: "A sidebar for your browser: Favorites, folders and this window's tabs.")
            if let problem = lib.problem { Banner(text: problem, style: .error) }
            ForEach(plan.sections, id: \.self) { section in
                self.section(section, rows: plan.rows)
                    .transition(Motion.reveal(reduceMotion))
            }
        }
        // Turning the sidebar on or off brings the rest of the page in or out.
        .animation(Motion.quick(reduceMotion), value: plan)
        .onAppear { tabs.start() }
    }

    @ViewBuilder
    private func section(_ section: SidebarPagePlan.Section, rows: [SidebarPagePlan.Row]) -> some View {
        switch section {
        case .sidebar: settings(rows)
        case .browsers: browsers
        case .options: options
        case .imports: SidebarImportSection()
        }
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

    private func settings(_ rows: [SidebarPagePlan.Row]) -> some View {
        DSSection {
            ForEach(rows, id: \.self) { row in
                switch row {
                case .show:
                    Toggle(isOn: $sidebar.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Show the sidebar")
                            Text("Sits against the edge of every browser window and moves with it. Drag the edge between them to resize that window's.")
                                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .windowsWarning:
                    Text("This version of macOS no longer tells betterlink one browser window from another, so no window gets a sidebar. Look for a newer betterlink.")
                        .foregroundStyle(DS.Palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                case .cornersNote:
                    Text("betterlink can't read each browser window's corner radius on this Mac, so every sidebar is cut for a 20 pt corner (Chrome's). Beside another browser its corners may not match the window's.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                case .accessibility:
                    HStack {
                        Text("betterlink needs Accessibility access to follow your browser windows.")
                            .foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Allow…") { sidebar.requestTrust() }
                    }
                case .side:
                    LabeledContent("Side") {
                        Picker("Side", selection: $sidebar.side) {
                            Text("Left").tag(SidebarSide.left)
                            Text("Right").tag(SidebarSide.right)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                case .shortcut:
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
                    Text("Collapses the browser's own tab strip.")
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
