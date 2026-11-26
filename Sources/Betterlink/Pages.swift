import AppKit
import BetterlinkCore
import SwiftUI

/// A page: a scrolling column of cards on the canvas, as the design system lays out.
struct PageForm<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.space6) { content }
                .padding(.horizontal, DS.Space.space8)
                // The page title lines up with the sidebar's header, below the traffic lights.
                .padding(.top, 44)
                .padding(.bottom, DS.Space.space8)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(DS.Palette.canvas)
        .labeledContentStyle(SpreadLabeledContentStyle())
    }
}

/// Label on the left, value on the right, like a settings row.
struct SpreadLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.space4) {
            configuration.label.foregroundStyle(DS.Palette.text)
            Spacer(minLength: DS.Space.space2)
            configuration.content.foregroundStyle(DS.Palette.textSecondary)
        }
    }
}

/// A titled card of rows separated by hairlines: panel, border-subtle,
/// radius-lg and shadow-card from the design system.
struct DSSection<Content: View, Header: View, Footer: View>: View {
    let content: Content
    let header: Header
    let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.space2) {
            header
                .font(DS.TextStyle.headline)
                .foregroundStyle(DS.Palette.text)
                .padding(.leading, DS.Space.space1)
            Group(subviews: content) { rows in
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            row
                                .padding(.horizontal, DS.Space.space4)
                                .padding(.vertical, DS.Space.space3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if i < rows.count - 1 {
                                Rectangle().fill(DS.Palette.borderSubtle).frame(height: 1)
                                    .padding(.leading, DS.Space.space4)
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous).fill(DS.Palette.panel))
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous)
                        .strokeBorder(DS.Palette.borderSubtle, lineWidth: 1))
                    .cardShadow()
                }
            }
            footer
                .padding(.horizontal, DS.Space.space1)
        }
    }
}

extension DSSection where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.init(content: content, header: { EmptyView() }, footer: { EmptyView() }) }
}
extension DSSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(content: content, header: { Text(title) }, footer: { EmptyView() }) }
}
extension DSSection where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.init(content: content, header: { EmptyView() }, footer: footer)
    }
}
extension DSSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension View {
    /// shadow-card from the design system, per appearance.
    func cardShadow() -> some View { modifier(CardShadow()) }
}

private struct CardShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let layers = scheme == .dark ? DS.Shadow.shadowCard.dark : DS.Shadow.shadowCard.light
        return layers.reduce(AnyView(content)) { view, l in
            AnyView(view.shadow(color: Color(.sRGB, red: l.red, green: l.green, blue: l.blue, opacity: l.alpha),
                                radius: l.blur / 2, x: l.x, y: l.y))
        }
    }
}

// MARK: Link Rules

struct RulesPage: View {
    @EnvironmentObject var model: AppModel
    @State private var editing = ProcessInfo.processInfo.environment["BETTERLINK_SHEET"] == "rules"
    @State private var editingKeys = ProcessInfo.processInfo.environment["BETTERLINK_SHEET"] == "keys"
    /// Keys the link tester pretends are held.
    @State private var testKeys: ModifierKeys = []
    /// BETTERLINK_TEST_LINK pre-fills the tester (a development aid for screenshots).
    @State private var testLink = ProcessInfo.processInfo.environment["BETTERLINK_TEST_LINK"] ?? ""

    var body: some View {
        PageForm {
            PageHeader(title: "Link Rules",
                           subtitle: "Each link opens in the first rule that matches, top to bottom. Everything else opens in the profile below.")
            if let err = model.rulesError {
                Banner(text: err, style: .error)
            }
            DSSection {
                if model.rules.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.space1) {
                        Text("No rules yet").font(DS.TextStyle.bodyStrong)
                        Text("Add one to send a site to a profile, such as domains matching example.com in Work.")
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .padding(.vertical, DS.Space.space1)
                }
                ForEach(Array(model.rules.enumerated()), id: \.element.id) { i, rule in
                    RuleSentence(index: i, rule: rule)
                }
                LabeledContent("Everything else opens in") {
                    ProfileMenu(selection: $model.fallback)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Edit Rules…") { editing = true }
                        .buttonStyle(.dsPrimary)
                        .disabled(model.rulesError != nil)
                        .keyboardShortcut("e", modifiers: .command)
                }
            }
            DSSection {
                if model.modifierRules.isEmpty {
                    VStack(alignment: .leading, spacing: DS.Space.space1) {
                        Text("No modifier keys").font(DS.TextStyle.bodyStrong)
                        Text("Hold keys such as ⌃⌘ while you click a link to open it in a chosen profile, whatever the rules above say.")
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    .padding(.vertical, DS.Space.space1)
                }
                ForEach(model.modifierRules) { rule in
                    KeysSentence(rule: rule)
                }
            } header: {
                Text("Modifier keys")
            } footer: {
                HStack {
                    Text("Checked first, before config.ts and Link Rules.").font(DS.TextStyle.caption)
                        .foregroundStyle(DS.Palette.textTertiary)
                    Spacer()
                    Button("Edit Keys…") { editingKeys = true }
                        .buttonStyle(.dsSecondary)
                        .disabled(model.rulesError != nil)
                }
            }
            DSSection("Test a link") {
                DSTextField(label: "Link to test", text: $testLink, prompt: "Paste a link to see where it would open", monospaced: true)
                if !model.modifierRules.isEmpty {
                    LabeledContent("Holding") { KeyChips(keys: $testKeys) }
                }
                if !testLink.isEmpty { TestResult(decision: model.preview(testLink, modifiers: testKeys)) }
            }
        }
        .sheet(isPresented: $editing) {
            RulesEditor(initial: model.rules) { editing = false }.environmentObject(model)
        }
        .sheet(isPresented: $editingKeys) {
            KeysEditor(initial: model.modifierRules) { editingKeys = false }.environmentObject(model)
        }
    }
}

/// "Open domains matching example.com in ● Work", as one line.
private struct RuleSentence: View {
    let index: Int
    let rule: Rule
    var body: some View {
        HStack(spacing: DS.Space.space2) {
            Text("\(index + 1)").font(DS.TextStyle.caption).monospacedDigit()
                .foregroundStyle(DS.Palette.textTertiary).frame(width: 14, alignment: .trailing)
            Text("Open \(rule.kind.label)").foregroundStyle(DS.Palette.textSecondary)
            Text(rule.pattern).font(DS.TextStyle.bodyStrong).lineLimit(1).truncationMode(.middle)
            Text("in").foregroundStyle(DS.Palette.textSecondary)
            ProfileLabel(ref: rule.target)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Hold ⌃⌘ to open in ● Work", as one line.
private struct KeysSentence: View {
    let rule: ModifierRule
    var body: some View {
        HStack(spacing: DS.Space.space2) {
            Text("Hold").foregroundStyle(DS.Palette.textSecondary)
            Text(rule.keys.symbols).font(DS.TextStyle.bodyStrong).accessibilityLabel(rule.keys.spoken)
            Text("to open in").foregroundStyle(DS.Palette.textSecondary)
            ProfileLabel(ref: rule.target)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct TestResult: View {
    let decision: Decision
    var body: some View {
        switch decision.action {
        case .refuse:
            Label(decision.reason, systemImage: "nosign").foregroundStyle(DS.Palette.textSecondary)
        case .open(let p, let arg):
            VStack(alignment: .leading, spacing: DS.Space.space1) {
                HStack(spacing: DS.Space.space2) {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(DS.Palette.textTertiary)
                    ProfileLabel(ref: p.ref)
                    Text(decision.reason).foregroundStyle(DS.Palette.textSecondary).lineLimit(2)
                }
                Text(arg).font(DS.TextStyle.code).foregroundStyle(DS.Palette.textTertiary)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
        }
    }
}

// MARK: Profiles

struct ProfilesPage: View {
    @EnvironmentObject var model: AppModel
    @State private var editing = ProcessInfo.processInfo.environment["BETTERLINK_SHEET"] == "profiles"

    var body: some View {
        PageForm {
            PageHeader(title: "Profiles",
                           subtitle: "The browsers and profiles your rules can open links in.")
            if !model.catalog.hasProfilesToChoose {
                Banner(text: "No profiles yet. Allow browser data access under Permissions and betterlink finds them, or add them by hand.",
                       style: .info)
            }
            ForEach(groupedProfiles(model.catalog.profiles), id: \.browser) { group in
                DSSection(model.browserName(group.browser)) {
                    ForEach(group.profiles) { p in
                        HStack(spacing: DS.Space.space2) {
                            ProfileLabel(ref: p.ref, showBrowser: false)
                            Spacer()
                            if !p.directory.isEmpty && p.directory != p.name {
                                Text(p.directory).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                            }
                            if p.directory.isEmpty {
                                Text("No profiles").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                            }
                        }
                    }
                }
            }
            DSSection {
                EmptyView()
            } footer: {
                HStack {
                    Text(model.browserAccess.values.contains(.readable)
                         ? "betterlink keeps this list in step with your browsers."
                         : "Without browser data access, add profiles by hand.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    Spacer()
                    Button("Edit Profiles…") { editing = true }.disabled(model.rulesError != nil)
                }
            }
        }
        .sheet(isPresented: $editing) {
            ProfilesEditor(initial: model.catalog.profiles.filter { !$0.directory.isEmpty }) { editing = false }
                .environmentObject(model)
        }
    }
}

// MARK: Permissions

struct PermissionsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PageForm {
            PageHeader(title: "Permissions",
                           subtitle: "What betterlink needs from macOS, and why. Only the first is required.")
            DSSection {
                PermissionRow(title: "Default browser",
                              why: "Links you click in other apps come to betterlink first, so it can send them to the right profile. Required.",
                              badge: model.isDefaultBrowser ? StatusBadge(text: "Allowed", kind: .success, symbol: "checkmark")
                                                            : StatusBadge(text: "Not set", kind: .warning)) {
                    if !model.isDefaultBrowser { Button("Make Default Browser") { model.makeDefaultBrowser() }.buttonStyle(.dsPrimary) }
                }
            }
            DSSection {
                PermissionRow(title: "Browser data",
                              why: "Lets betterlink read each browser's list of profiles, so new profiles show up by themselves. "
                                 + "macOS calls this Full Disk Access. Optional: without it, add profiles by hand.",
                              badge: browserDataBadge) {
                    Button("Open Privacy Settings") { model.openFullDiskAccessSettings() }
                }
                ForEach(model.browsers.filter { $0.family != .plain }) { b in
                    let access = model.browserAccess[b.bundleId] ?? .missing
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(b.name).foregroundStyle(DS.Palette.textSecondary)
                            Spacer()
                            switch access {
                            case .readable: StatusBadge(text: access.badge(fullDiskAccess: model.fullDiskAccess), kind: .success, symbol: "checkmark")
                            case .missing: StatusBadge(text: access.badge(fullDiskAccess: model.fullDiskAccess), kind: .neutral)
                            default: StatusBadge(text: access.badge(fullDiskAccess: model.fullDiskAccess), kind: .warning)
                            }
                        }
                        if let why = access.explanation(browser: b.name, fullDiskAccess: model.fullDiskAccess) {
                            Text(why).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, DS.Space.space4)
                }
            } footer: {
                Text(fullDiskAccessNote)
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
            }
            DSSection {
                PermissionRow(title: "Open at login",
                              why: "Starts betterlink when you log in, so the first link after a restart opens without a pause. Optional.",
                              badge: model.opensAtLogin ? StatusBadge(text: "On", kind: .success, symbol: "checkmark")
                                                        : StatusBadge(text: "Off", kind: .neutral)) {
                    Toggle("Open at login", isOn: Binding(get: { model.opensAtLogin }, set: { model.setOpensAtLogin($0) }))
                        .labelsHidden().fixedSize()
                }
            }
        }
        .onAppear { model.refreshPermissions() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var browserDataBadge: StatusBadge {
        let states = model.browsers.filter { $0.family != .plain }.compactMap { model.browserAccess[$0.bundleId] }
        if let bad = states.first(where: { $0 != .readable && $0 != .missing }) {
            return StatusBadge(text: bad.badge(fullDiskAccess: model.fullDiskAccess), kind: .warning)
        }
        if states.contains(.readable) { return StatusBadge(text: "Allowed", kind: .success, symbol: "checkmark") }
        return StatusBadge(text: "Optional", kind: .neutral)
    }

    private var fullDiskAccessNote: String {
        let fda = switch model.fullDiskAccess {
        case true?: "Full Disk Access: on. "
        case false?: "Full Disk Access: off. "
        case nil: ""   // no probe could tell; saying "unknown" only worries people
        }
        return fda + "After changing it in System Settings, come back here; betterlink checks again when the window is active."
    }
}

/// One permission: what it is, why, its status, and the control that fixes it.
private struct PermissionRow<Action: View>: View {
    let title: String
    let why: String
    let badge: StatusBadge
    @ViewBuilder let action: Action
    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.space4) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.space2) {
                    Text(title).font(DS.TextStyle.bodyStrong)
                    badge
                }
                Text(why).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.space2)
            action
        }
        .padding(.vertical, DS.Space.space1)
    }
}

// MARK: config.ts

struct ConfigPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PageForm {
            PageHeader(title: "config.ts",
                           subtitle: "Optional rules written in TypeScript, for anything Link Rules can't express. config.ts runs first; return undefined to let Link Rules decide.")
            DSSection("Status") {
                switch model.configStatus {
                case .absent:
                    LabeledContent("config.ts") { StatusBadge(text: "Not created", kind: .neutral) }
                case .loading:
                    LabeledContent("config.ts") { ProgressView().controlSize(.small) }
                case .loaded(let date):
                    LabeledContent("config.ts") {
                        HStack {
                            Text("Checked \(date.formatted(date: .omitted, time: .shortened))")
                                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                            StatusBadge(text: "Running", kind: .success, symbol: "checkmark")
                        }
                    }
                case .failed(let msg, let previous):
                    LabeledContent("config.ts") { StatusBadge(text: "Not loaded", kind: .warning) }
                    Banner(text: previous ? "The last version that worked is still running." : "Links skip config.ts until it's fixed.",
                           style: .warning)
                    Text(msg).font(DS.TextStyle.code).foregroundStyle(DS.Palette.text).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            DSSection {
                LabeledContent("File") {
                    Text(model.paths.configFile.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(DS.TextStyle.code).foregroundStyle(DS.Palette.textTertiary).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("Reload") { model.reloadConfig(force: true) }
                    Button("Show in Finder") { model.revealConfig() }.disabled(model.configStatus == .absent)
                    Button(model.configStatus == .absent ? "Create config.ts" : "Open in Editor") { model.editConfig() }
                        .buttonStyle(.dsPrimary)
                }
            }
            DSSection("Example") {
                Text("""
                // Links from Slack to example.com open in Chrome's Work profile.
                export default function route(link: Link): Target | undefined {
                  const fromSlack = link.opener === "com.tinyspeck.slackmacgap";
                  if (fromSlack && link.host.endsWith("example.com")) {
                    return { browser: "Google Chrome", profile: "Work" };
                  }
                  return undefined;
                }
                """)
                .font(DS.TextStyle.code).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
            }
        }
    }
}

// MARK: General

struct GeneralPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var updater = Updater.shared
    var body: some View {
        PageForm {
            PageHeader(title: "General", subtitle: "Where betterlink keeps its settings, and what it shows.")
            DSSection {
                LabeledContent("Settings folder") {
                    Text(model.paths.directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(DS.TextStyle.code).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: DS.Space.space2) {
                    Spacer()
                    Button("Show in Finder") { model.revealSettingsFolder() }
                    Button("Use Standard Folder") { model.useSettingsFolder(nil) }
                        .disabled(model.folderFromEnvironment || model.paths.directory == SettingsFolder.defaultDirectory)
                    Button("Change…") { chooseFolder() }.disabled(model.folderFromEnvironment)
                }
            } header: {
                Text("Settings")
            } footer: {
                Text(model.folderFromEnvironment
                     ? "Set by BETTERLINK_HOME, so it can't be changed here."
                     : "rules.json (your Link Rules and profiles) and config.ts live here. Pick a folder you back up or sync; betterlink copies them over and leaves the old folder as it is.")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SyncSettingsSection()
            DSSection("Menu bar") {
                Toggle("Show betterlink in the menu bar", isOn: $model.showsMenuBarIcon)
                Text(model.showsMenuBarIcon
                     ? "The icon opens this window and lists recent links. Closing the window (⌘W or the red button) keeps betterlink running."
                     : "betterlink keeps running and routing links. To get back here, open betterlink again from Spotlight, Launchpad or Finder.")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Quit betterlink") { NSApp.terminate(nil) }
                }
            }
            DSSection("Link toast") {
                Toggle("Show a toast when a rule picks the profile", isOn: $model.showsLinkToast)
                LabeledContent("Position") {
                    DSPicker(accessibility: "Toast position", selection: $model.linkToastPosition,
                             options: LinkToast.Position.allCases) { $0.label }
                        .frame(width: 200)
                }
                .disabled(!model.showsLinkToast)
                HStack {
                    Text("A small badge with the profile and what chose it: held keys, config.ts or a Link Rule. Links that open in the fallback show none. This Mac only.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Preview") { model.previewLinkToast() }.disabled(!model.showsLinkToast)
                }
            }
            DSSection("Updates") {
                Toggle("Check for updates automatically", isOn: $updater.automaticallyChecks)
                Text(updater.isAvailable
                     ? "Once a day betterlink asks GitHub whether a newer version is out. It sends nothing about you or your links. Every update is checked against betterlink's signing key before it installs."
                     : "This build has no update key, so it doesn't check for updates. Release builds do.")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textSecondary)
                    Spacer()
                    Button("Check Now") { updater.checkNow() }.disabled(!updater.isAvailable)
                }
            }
            DSSection("Log") {
                Toggle("Show the log in the sidebar", isOn: $model.showLog)
                Text("The log lists every link and where it went. It is kept in memory only and cleared when betterlink quits.")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where betterlink keeps rules.json and config.ts."
        if panel.runModal() == .OK, let url = panel.url { model.useSettingsFolder(url) }
    }
}

// MARK: Log

struct LogPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        PageForm {
            PageHeader(title: "Log", subtitle: "Every link betterlink handled, newest first. Kept in memory only.")
            DSSection {
                if model.log.entries.isEmpty {
                    Text("Nothing yet. Click a link in any app.").foregroundStyle(DS.Palette.textSecondary)
                }
                ForEach(model.log.entries.reversed()) { e in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: DS.Space.space2) {
                            Text(e.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                            if let opener = e.opener { Text(opener) }
                            Spacer()
                            if let p = e.profileName { Text(p).fontWeight(.medium).foregroundStyle(DS.Palette.textSecondary) }
                        }
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        if let link = e.link {
                            Text(link).font(DS.TextStyle.code).lineLimit(1).truncationMode(.middle)
                        }
                        Text(e.message).foregroundStyle(DS.Palette.textSecondary)
                    }
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
                }
            } footer: {
                HStack { Spacer(); Button("Clear") { model.clearLog() }.disabled(model.log.entries.isEmpty) }
            }
        }
    }
}

// MARK: About

struct AboutPage: View {
    var body: some View {
        PageForm {
            DSSection {
                HStack(spacing: DS.Space.space4) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("betterlink").font(DS.TextStyle.title1).tracking(DS.TextStyle.title1Tracking)
                        Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                            .foregroundStyle(DS.Palette.textSecondary)
                        Text("Every link, in the right browser and profile.").foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                .padding(.vertical, DS.Space.space2)
            }
            TourAboutSection()
            DSSection("Privacy") {
                Text("betterlink has no network code. It sees the links you open, keeps them in memory only, and sends nothing anywhere.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            DSSection("Acknowledgements") {
                LabeledContent("Finch", value: "MIT License. betterlink started as a fork.")
                LabeledContent("TypeScript 6.0.3", value: "Apache License 2.0. Bundled to check config.ts.")
                LabeledContent("Finicky", value: "MIT License. Browser bundle ids and data folders.")
            }
        }
    }
}

// MARK: Agents

struct AgentsPage: View {
    @EnvironmentObject var model: AppModel
    @State private var copied = false

    var body: some View {
        PageForm {
            PageHeader(title: "Agents",
                       subtitle: "Let a coding agent such as Claude Code or Codex set up betterlink for you. It can change everything this window can.")
            DSSection {
                HStack(alignment: .center, spacing: DS.Space.space4) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: DS.Space.space2) {
                            Text("betterlink command").font(DS.TextStyle.bodyStrong)
                            installBadge
                        }
                        Text(installDetail)
                            .foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Space.space2)
                    switch model.commandInstall {
                    case .installed:
                        Button("Uninstall") { model.uninstallCommand() }.buttonStyle(.dsGhost)
                    case .notInstalled:
                        Button("Install Command") { model.installCommand() }.buttonStyle(.dsPrimary)
                    case .pointsElsewhere:
                        Button("Reinstall") { model.installCommand() }.buttonStyle(.dsPrimary)
                    case .blocked:
                        EmptyView()
                    }
                }
                LabeledContent("Path") {
                    Text(model.commandLink.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(DS.TextStyle.code).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
                }
            } header: {
                Text("Command")
            } footer: {
                Text("The command ships inside betterlink. Installing links it into ~/.local/bin; if your shell can't find it, add ~/.local/bin to your PATH, or use the full path, as the prompt below does.")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DSSection {
                Text(model.agentPrompt)
                    .font(DS.TextStyle.code)
                    .foregroundStyle(DS.Palette.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Paste this into your agent's chat to start.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    Spacer()
                    Button { copy() } label: {
                        Label(copied ? "Copied" : "Copy Prompt", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.dsPrimary)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
            } header: {
                Text("Prompt")
            }
            DSSection("What agents can do") {
                ForEach(capabilities, id: \.0) { item in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.space3) {
                        Text(item.0).font(DS.TextStyle.code).foregroundStyle(DS.Palette.text).frame(width: 190, alignment: .leading)
                        Text(item.1).foregroundStyle(DS.Palette.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .onAppear { model.refreshCommandInstall() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshCommandInstall()
        }
    }

    private var capabilities: [(String, String)] {
        [("rules", "List, add, change, reorder and remove Link Rules."),
         ("keys", "Choose modifier keys, such as ⌃⌘, that open a clicked link in a profile."),
         ("fallback", "Choose where links that match no rule open."),
         ("profiles", "List, add, rename and recolour profiles, or import them from your browsers."),
         ("test", "Show where any link would open, and why, without opening it."),
         ("config", "Create config.ts and type-check it exactly as betterlink does."),
         ("folder · settings", "Move the settings folder; show or hide the Log page."),
         ("default-browser · login", "Ask macOS to make betterlink the default browser; open at login.")]
    }

    private var installBadge: StatusBadge {
        switch model.commandInstall {
        case .installed: StatusBadge(text: "Installed", kind: .success, symbol: "checkmark")
        case .notInstalled: StatusBadge(text: "Not installed", kind: .neutral)
        case .pointsElsewhere: StatusBadge(text: "Points elsewhere", kind: .warning)
        case .blocked: StatusBadge(text: "Name taken", kind: .warning)
        }
    }

    private var installDetail: String {
        switch model.commandInstall {
        case .installed: "Agents (and you) can run betterlink in Terminal."
        case .notInstalled: "Link the command into ~/.local/bin so agents can run betterlink."
        case .pointsElsewhere(let p): "The link points at \(p.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Reinstall to point it at this copy."
        case .blocked: "Something that isn't betterlink's link is already at ~/.local/bin/betterlink, so betterlink leaves it alone."
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.agentPrompt, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
