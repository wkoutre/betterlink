import AppKit
import SwiftUI
import BetterlinkCore
import TabSyncCore

/// What the sidebar panel shows, like Arc's and Dia's sidebars: the Sidebar
/// Profile linked to the front window's browser profile (its Favorites grid and
/// folders of saved links), then that window's other open tabs.
struct SidebarView: View {
    @EnvironmentObject var sidebar: SidebarController
    @ObservedObject private var tabs = TabsModel.shared
    @ObservedObject private var lib = SidebarLibraryModel.shared
    @State private var newURL = ""
    @State private var renaming: UUID?
    @State private var draftName = ""
    /// A folder or profile waiting for "Delete" to be confirmed.
    @State private var confirmDelete: (id: UUID, name: String, count: Int)?
    @FocusState private var nameFocused: Bool

    var body: some View {
        let match = Self.match(target: sidebar.target, sessions: tabs.sessions)
        let profile = lib.library.profile(for: match.flatMap { $0.certain ? tabs.profileRef($0.session) : nil })
        let windowTabs = match?.window?.tabs ?? []
        VStack(alignment: .leading, spacing: 0) {
            header(match: match, profile: profile)
            if let m = match, let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.space2) {
                        favorites(profile, m, windowTabs)
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(profile.items) { item in node(item, depth: 0, profile, m, windowTabs) }
                            Button { newFolder(in: nil, profile) } label: {
                                Label("New Folder", systemImage: "folder.badge.plus").font(DS.TextStyle.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .padding(.horizontal, DS.Space.space2)
                            .padding(.vertical, 4)
                        }
                        Divider().padding(.horizontal, DS.Space.space2)
                        newTabField(m)
                        LazyVStack(alignment: .leading, spacing: 1) {
                            // Tabs that are open saved links show in their folder instead.
                            ForEach(windowTabs.filter { !Self.claimed(by: profile, in: windowTabs).contains($0.id) }) { tab in
                                SidebarTabRow(tab: tab) {
                                    tabs.activate(tab, in: m.session)
                                } close: {
                                    tabs.close(tab, in: m.session)
                                }
                                .draggable(Self.dragKey(tab))
                                .contextMenu { tabMenu(tab, profile) }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.space2)
                    .padding(.bottom, DS.Space.space4)
                }
            } else {
                Text(emptyText)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.space4)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog("Delete \"\(confirmDelete?.name ?? "")\" and everything in it?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete \(confirmDelete?.count ?? 0) saved items", role: .destructive) {
                if let d = confirmDelete, let p = profile { lib.change(profile: p.id) { $0.remove(d.id) } }
                confirmDelete = nil
            }
        }
    }

    // MARK: - Header

    private func header(match: Match?, profile: SidebarProfile?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Which Sidebar Profile this browser profile shows; pick or make one.
            Menu {
                if let m = match, m.certain, let ref = tabs.profileRef(m.session) {
                    Section("Show for \(tabs.profileName(m.session) ?? "this profile")") {
                        ForEach(lib.library.profiles) { sp in
                            Button { lib.change { $0.link(ref, to: sp.id) } } label: {
                                if sp.id == profile?.id { Label(sp.name, systemImage: "checkmark") } else { Text(sp.name) }
                            }
                        }
                    }
                    Button("New Sidebar Profile") {
                        lib.change { l in
                            let sp = SidebarProfile(name: tabs.profileName(m.session) ?? "Profile \(l.profiles.count + 1)")
                            l.profiles.append(sp)
                            l.link(ref, to: sp.id)
                        }
                    }
                } else {
                    Text("Waiting to learn this window's browser profile")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(profile?.name ?? "Sidebar").font(DS.TextStyle.headline)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(DS.Palette.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Sidebar Profile: \(profile?.name ?? "none")")
            if let m = match {
                Text([m.session.browser, m.certain ? tabs.profileName(m.session) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.space4)
        // Clear of the browser window's traffic lights when bound on the left.
        .padding(.top, 30)
        .padding(.bottom, DS.Space.space2)
    }

    // MARK: - Favorites

    private func favorites(_ p: SidebarProfile, _ m: Match, _ open: [BrowserTab]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 64), spacing: 6)], spacing: 6) {
            ForEach(p.favorites) { link in
                let isOpen = open.contains { SavedLink.same($0.url, link.url) }
                Button { openOrSwitch(link, m) } label: {
                    Favicon(url: link.icon ?? "")
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isOpen ? DS.Palette.selected : DS.Palette.hover.opacity(0.6)))
                }
                .buttonStyle(.plain)
                .help(link.title)
                .accessibilityLabel(link.title)
                .contextMenu {
                    Button("Remove from Favorites") { lib.change(profile: p.id) { $0.remove(link.id) } }
                }
            }
        }
        .padding(.horizontal, DS.Space.space1)
        // Drop a tab here to make it a Favorite.
        .frame(minHeight: p.favorites.isEmpty ? 24 : nil)
        .overlay {
            if p.favorites.isEmpty {
                Text("Drag a tab here for a Favorite").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .dropDestination(for: String.self) { keys, _ in
            let found = keys.compactMap { Self.tab(forDragKey: $0, in: open) }
            for t in found { lib.change(profile: p.id) { $0.addFavorite(Self.saved(t)) } }
            return !found.isEmpty
        }
    }

    // MARK: - Folders

    private func node(_ item: SidebarItem, depth: Int, _ p: SidebarProfile, _ m: Match, _ open: [BrowserTab]) -> AnyView {
        switch item {
        case .folder(let f):
            return AnyView(VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Space.space2) {
                    Image(systemName: f.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        .foregroundStyle(DS.Palette.textTertiary)
                    Image(systemName: "folder").foregroundStyle(DS.Palette.textSecondary)
                    nameOrField(f.id, f.name, p)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 14)
                .rowStyle()
                .onTapGesture { lib.change(profile: p.id) { $0.toggleExpanded(f.id) } }
                .accessibilityElement(children: renaming == f.id ? .contain : .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Folder \(f.name), \(f.expanded ? "open" : "closed")")
                .accessibilityAction { lib.change(profile: p.id) { $0.toggleExpanded(f.id) } }
                .contextMenu {
                    Button("New Folder Inside") { newFolder(in: f.id, p) }
                    Button("Rename") { startRename(f.id, f.name) }
                    Button("Delete Folder", role: .destructive) {
                        // A folder with things in it asks first (review F6).
                        let n = SidebarProfile.links(in: f.items).count + f.items.filter { if case .folder = $0 { return true }; return false }.count
                        if n == 0 { lib.change(profile: p.id) { $0.remove(f.id) } } else { confirmDelete = (f.id, f.name, n) }
                    }
                }
                .dropDestination(for: String.self) { keys, _ in drop(keys, into: f.id, p, open) }
                if f.expanded {
                    ForEach(f.items) { child in node(child, depth: depth + 1, p, m, open) }
                } else {
                    // Closed, it still lists its open items, as Arc and Dia do.
                    ForEach(SidebarProfile.links(in: f.items).filter { l in open.contains { SavedLink.same($0.url, l.url) } }) { l in
                        node(.link(l), depth: depth + 1, p, m, open)
                    }
                }
            })
        case .link(let l):
            let tab = open.first { SavedLink.same($0.url, l.url) }
            return AnyView(HStack(spacing: DS.Space.space2) {
                Favicon(url: tab?.favIconUrl ?? l.icon ?? "")
                nameOrField(l.id, l.title, p)
                    .foregroundStyle(tab == nil ? DS.Palette.textSecondary : DS.Palette.text)
                Spacer(minLength: 0)
                // Open: like Arc, the saved link stands for its tab.
                if tab != nil { Circle().fill(DS.Palette.accent).frame(width: 5, height: 5).accessibilityLabel("open") }
            }
            .padding(.leading, CGFloat(depth) * 14 + 18)
            .rowStyle(selected: tab?.active == true)
            .onTapGesture { openOrSwitch(l, m) }
            .accessibilityElement(children: renaming == l.id ? .contain : .ignore)
            .accessibilityLabel(tab == nil ? l.title : "\(l.title), open")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openOrSwitch(l, m) }
            .draggable("betterlink-saved:\(l.id.uuidString)")
            .contextMenu {
                Button("Rename") { startRename(l.id, l.title) }
                if let tab { Button("Close Tab") { tabs.close(tab, in: m.session) } }
                Button("Remove", role: .destructive) { lib.change(profile: p.id) { $0.remove(l.id) } }
            })
        }
    }

    @ViewBuilder
    private func nameOrField(_ id: UUID, _ name: String, _ p: SidebarProfile) -> some View {
        if renaming == id {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .font(DS.TextStyle.body)
                .focused($nameFocused)
                .onAppear { nameFocused = true }
                .onSubmit { lib.change(profile: p.id) { $0.rename(id, to: draftName) }; renaming = nil }
                .onExitCommand { renaming = nil }
        } else {
            Text(name).font(DS.TextStyle.body).lineLimit(1)
        }
    }

    private func startRename(_ id: UUID, _ name: String) {
        draftName = name
        renaming = id
    }

    private func newFolder(in parent: UUID?, _ p: SidebarProfile) {
        var made: UUID?
        lib.change(profile: p.id) { made = $0.addFolder("New Folder", in: parent) }
        if let made { startRename(made, "New Folder") }
    }

    /// A tab dropped on a folder is saved into it; a saved link dropped on a
    /// folder moves there.
    private func drop(_ keys: [String], into folder: UUID, _ p: SidebarProfile, _ open: [BrowserTab]) -> Bool {
        var did = false
        for k in keys {
            if let t = Self.tab(forDragKey: k, in: open) {
                lib.change(profile: p.id) { $0.addLink(Self.saved(t), in: folder) }
                did = true
            } else if k.hasPrefix("betterlink-saved:"), let id = UUID(uuidString: String(k.dropFirst("betterlink-saved:".count))) {
                lib.change(profile: p.id) { $0.move(id, into: folder) }
                did = true
            }
        }
        return did
    }

    // MARK: - Tabs

    private func newTabField(_ m: Match) -> some View {
        HStack(spacing: DS.Space.space2) {
            Image(systemName: "plus").foregroundStyle(DS.Palette.textTertiary)
            TextField("New Tab", text: $newURL)
                .textFieldStyle(.plain)
                .font(DS.TextStyle.body)
                .onSubmit {
                    guard !newURL.isEmpty else { return }
                    tabs.open(newURL, in: m.session, windowId: m.window?.id)
                    newURL = ""
                    sidebar.returnFocusToBrowser()
                }
        }
        .padding(.horizontal, DS.Space.space2)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func tabMenu(_ tab: BrowserTab, _ p: SidebarProfile) -> some View {
        Button("Add to Favorites") { lib.change(profile: p.id) { $0.addFavorite(Self.saved(tab)) } }
        Menu("Save to Folder") {
            ForEach(Self.folders(p.items, prefix: "")) { f in
                Button(f.label) { lib.change(profile: p.id) { $0.addLink(Self.saved(tab), in: f.id) } }
            }
            Button("New Folder…") {
                var made: UUID?
                lib.change(profile: p.id) {
                    made = $0.addFolder("New Folder")
                    if let made { $0.addLink(Self.saved(tab), in: made) }
                }
                if let made { startRename(made, "New Folder") }
            }
        }
    }

    /// Switches to the saved link's tab when it is open in this window (or
    /// another window of the same profile), else opens it here.
    private func openOrSwitch(_ link: SavedLink, _ m: Match) {
        let here = m.window?.tabs ?? []
        let anywhere = m.session.store.orderedWindows.flatMap(\.tabs)
        if let t = here.first(where: { SavedLink.same($0.url, link.url) }) ?? anywhere.first(where: { SavedLink.same($0.url, link.url) }) {
            tabs.activate(t, in: m.session)
        } else {
            tabs.open(link.url, in: m.session, windowId: m.window?.id)
        }
        sidebar.returnFocusToBrowser()
    }

    // MARK: - Helpers

    struct FolderChoice: Identifiable { var id: UUID; var label: String }

    static func folders(_ items: [SidebarItem], prefix: String) -> [FolderChoice] {
        items.flatMap { item -> [FolderChoice] in
            guard case .folder(let f) = item else { return [] }
            return [FolderChoice(id: f.id, label: prefix + f.name)] + folders(f.items, prefix: prefix + f.name + " › ")
        }
    }

    static func saved(_ t: BrowserTab) -> SavedLink {
        SavedLink(title: t.title.isEmpty ? t.url : t.title, url: t.url, icon: t.favIconUrl.hasPrefix("data:") ? t.favIconUrl : nil)
    }

    /// The tabs saved links stand for: for each saved link, its first matching
    /// tab. Those show with their link; every other tab, a second tab at the
    /// same address included, shows in the tab list (review F5).
    static func claimed(by p: SidebarProfile, in tabs: [BrowserTab]) -> Set<Int> {
        var taken = Set<Int>()
        for l in p.allLinks {
            if let t = tabs.first(where: { !taken.contains($0.id) && SavedLink.same($0.url, l.url) }) { taken.insert(t.id) }
        }
        return taken
    }

    static func dragKey(_ t: BrowserTab) -> String { "betterlink-tab:\(t.id)" }

    static func tab(forDragKey k: String, in tabs: [BrowserTab]) -> BrowserTab? {
        guard k.hasPrefix("betterlink-tab:"), let id = Int(k.dropFirst("betterlink-tab:".count)) else { return nil }
        return tabs.first { $0.id == id }
    }

    private var emptyText: String {
        guard let t = sidebar.target else { return "" }
        return "Tabs aren't set up for \(t.appName). In betterlink, open Tabs and choose Set Up next to \(t.appName), then load the Tabs extension in it."
    }

    struct Match {
        var session: BrowserSession
        var window: TabStore.WindowEntry?
        /// False for a best guess between profiles: its profile isn't named.
        var certain = true
    }

    /// The browser session (profile) and window behind the bound window: the
    /// browser's focused window, else its frame (WindowMatch.front), else the
    /// one window across every profile whose active tab titles it.
    static func match(target: WindowTracker.Target?, sessions: [BrowserSession]) -> Match? {
        guard let t = target else { return nil }
        // Each browser profile is its own session. The browser's focused window
        // is the one in front; its frame is the fallback (see WindowMatch.front).
        let mine = sessions.filter { $0.browserPid == Int(t.pid) }
        let frame = NSScreen.screens.first.map { screen -> WindowBounds in
            let ax = SidebarGeometry.ax(fromCocoa: t.frame, mainScreenHeight: screen.frame.height)
            return WindowBounds(left: ax.minX, top: ax.minY, width: ax.width, height: ax.height)
        }
        if let hit = WindowMatch.front(frame: frame, in: mine), let s = mine.first(where: { $0.id == hit.session }) {
            return Match(session: s, window: s.store.orderedWindows.first { $0.id == hit.windowId })
        }
        // Not settled yet (no single focused window, no frame match): the one
        // window, across every profile, whose active tab titles the window in
        // front. Anything less certain is a guess, shown without a profile name.
        let candidates = mine.isEmpty ? sessions.filter { $0.browser == t.appName } : mine
        let byTitle = candidates.flatMap { s in
            s.store.orderedWindows.filter { w in
                guard let title = w.tabs.first(where: \.active)?.title, !title.isEmpty else { return false }
                return t.title.hasPrefix(title)
            }.map { (s, $0) }
        }
        if byTitle.count == 1 { return Match(session: byTitle[0].0, window: byTitle[0].1) }
        guard let s = candidates.first else { return nil }
        return Match(session: s, window: s.store.orderedWindows.first { $0.window.focused } ?? s.store.orderedWindows.first,
                     certain: false)
    }
}

private struct SidebarTabRow: View {
    let tab: BrowserTab
    let activate: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.space2) {
            Favicon(url: tab.favIconUrl)
            Text(tab.title.isEmpty ? tab.url : tab.title)
                .font(DS.TextStyle.body)
                .lineLimit(1)
                .foregroundStyle(DS.Palette.text)
            Spacer(minLength: 0)
            if tab.audible {
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(DS.Palette.textTertiary)
            }
            if hovering {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityLabel("Close \(tab.title)")
            }
        }
        .padding(.horizontal, DS.Space.space2)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tab.active ? DS.Palette.selected : (hovering ? DS.Palette.hover : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: activate)
        .accessibilityAddTraits(tab.active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
        .accessibilityAction(named: Text("Close")) { close() }
    }
}

private extension View {
    func rowStyle(selected: Bool = false) -> some View {
        self.padding(.horizontal, DS.Space.space2)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? DS.Palette.selected : .clear))
            .contentShape(Rectangle())
    }
}
