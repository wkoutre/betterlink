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
    private var pal: SidebarColors { SidebarColors(sidebar.palette) }
    @ObservedObject private var lib = SidebarLibraryModel.shared
    /// The tabs saved links hold (a saved link keeps its tab as it navigates).
    @ObservedObject private var holds = SidebarHoldsModel.shared
    @State private var newURL = ""
    @State private var renaming: UUID?
    @State private var renamingProfile: UUID?
    /// The header's own field: a folder or link rename may be open too (review F2).
    @State private var profileDraft = ""
    @FocusState private var profileNameFocused: Bool
    /// The row a drag is over, and where in it.
    @State private var dropTarget: DropTarget?
    @State private var rowSizes: [UUID: CGSize] = [:]
    /// The last delete, for Undo: which profile, what went and from where.
    @State private var undo: (profile: UUID, removed: SidebarProfile.Removed, label: String, at: Date)?
    /// A folder with things in it waiting for its delete to be confirmed.
    @State private var confirmDelete: (id: UUID, name: String, count: Int)?
    /// What is being dragged from the sidebar, so a row can refuse a drop
    /// that wouldn't move anything (a folder into itself, say).
    @State private var dragging: String?
    @State private var confirmProfileDelete: SidebarProfile?
    @State private var draftName = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Every change the sidebar makes is animated, briefly: Motion.quick, or
    /// nothing when the viewer has Reduce Motion on.
    private func animate(_ body: () -> Void) {
        withAnimation(Motion.quick(reduceMotion), body)
    }

    /// Changes a Sidebar Profile, animated.
    private func edit(_ id: UUID, _ change: (inout SidebarProfile) -> Void) {
        animate { lib.change(profile: id, change) }
    }
    @FocusState private var nameFocused: Bool

    var body: some View {
        let look = Self.look(target: sidebar.target, sessions: tabs.sessions)
        let profile = lib.library.profile(for: look.match.flatMap { $0.certain ? tabs.profileRef($0.session) : nil })
        // Which tab each saved link stands for, worked out once for this redraw.
        let match = look.match.map { $0.resolving(profile, holds: holds.holds(in: $0.session)) }
        let windowTabs = match?.window?.tabs ?? []
        let iconsToLearn = Self.iconsToLearn(profile, match)
        VStack(alignment: .leading, spacing: 0) {
            header(match: match, profile: profile)
                // Another profile now: an open rename belonged to the last one.
                .onChange(of: profile?.id) { renamingProfile = nil }
            if let m = match, let profile {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.space2) {
                        favorites(profile, m, windowTabs)
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(profile.items) { item in
                                node(item, depth: 0, profile, m, windowTabs).transition(Motion.reveal(reduceMotion))
                            }
                            Button { newFolder(in: nil, profile) } label: {
                                Label("New Folder", systemImage: "folder.badge.plus").font(DS.TextStyle.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(pal.textTertiary)
                            .padding(.horizontal, DS.Space.space2)
                            .padding(.vertical, 4)
                            // Dropped here: the end of the top level.
                            .dropDestination(for: String.self) { keys, _ in
                                dragging = nil
                                return apply(keys, at: .items(parent: nil, index: profile.items.count), profile, windowTabs)
                            }
                        }
                        // A closed folder lists its open items, which come and go
                        // with tabs: animate those in place too (review F1).
                        .animation(Motion.quick(reduceMotion), value: windowTabs.map { [$0.id, $0.active ? 1 : 0] })
                        Divider().padding(.horizontal, DS.Space.space2)
                        newTabField(m)
                        LazyVStack(alignment: .leading, spacing: 1) {
                            // Tabs that are open saved links show in their folder instead.
                            ForEach(windowTabs.filter { !m.links.claimed.contains($0.id) }) { tab in
                                SidebarTabRow(tab: tab, canMute: m.session.can(.mute)) {
                                    tabs.activate(tab, in: m.session)
                                } close: {
                                    tabs.close(tab, in: m.session)
                                } mute: {
                                    tabs.setMuted(!tab.muted, tab, in: m.session)
                                }
                                .onDrag { drag(Self.dragKey(tab)) }
                                // Drop a tab before or after another to reorder the window's tabs.
                                .modifier(tabDropRow(tab, m, windowTabs))
                                .contextMenu { tabMenu(tab, profile, m, windowTabs) }
                                .transition(Motion.reveal(reduceMotion))
                            }
                        }
                        // Tabs opening, closing, moving and switching animate in place.
                        .animation(Motion.quick(reduceMotion), value: windowTabs.map { [$0.id, $0.active ? 1 : 0] })
                    }
                    .padding(.horizontal, DS.Space.space2)
                    .padding(.bottom, DS.Space.space4)
                }
            } else {
                Text(emptyText(look))
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(pal.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(DS.Space.space4)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Undo for the last delete, at the bottom for a few seconds.
        .overlay(alignment: .bottom) { if let u = undo { undoBar(u) } }
        // A folder with things in it asks first (review F6), then offers Undo too.
        .confirmationDialog("Delete \"\(confirmDelete?.name ?? "")\" and everything in it?",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Delete \(confirmDelete?.count ?? 0) saved items", role: .destructive) {
                if let d = confirmDelete, let p = profile { deleteWithUndo(d.id, d.name, p) }
                confirmDelete = nil
            }
        }
        // The browser profile's frame color, like the browser's own window.
        .onChange(of: match.flatMap { tabs.profileColor($0.session) }, initial: true) { _, rgb in sidebar.setTint(rgb) }
        // A saved link with no icon (an imported one) takes its open tab's, once.
        .onChange(of: iconsToLearn, initial: true) { _, icons in
            if let p = profile, !icons.isEmpty { lib.change(profile: p.id) { $0.learnIcons(icons) } }
        }
        // Anything left on system colors (text fields, their placeholders,
        // the folder names) follows the palette: its text color by default and
        // a light or dark scheme matching the profile color (review F1).
        .foregroundStyle(pal.text)
        .modifier(SchemeOverride(scheme: pal.scheme))
        .environment(\.sidebarColors, pal)
    }

    // MARK: - Header

    private func header(match: Match?, profile: SidebarProfile?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.space2) {
                if let p = profile, renamingProfile == p.id {
                    TextField("Name", text: $profileDraft)
                        .textFieldStyle(.plain)
                        .font(DS.TextStyle.headline)
                        .foregroundStyle(pal.text)
                        .focused($profileNameFocused)
                        .onAppear { profileNameFocused = true }
                        .onSubmit { renameProfile(p.id) }
                        .onExitCommand { renamingProfile = nil }
                } else {
                    Text(profile?.name ?? "Sidebar")
                        .font(DS.TextStyle.headline)
                        .foregroundStyle(pal.text)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                // The Sidebar Profile's settings: which one this browser profile
                // shows, a new one, rename, delete, and the sidebar's settings page.
                Menu {
                    profileMenu(match: match, profile: profile)
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(pal.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sidebar Profile settings")
                .accessibilityLabel("Sidebar Profile settings")
            }
            if let m = match {
                Text([m.session.browser, m.certain ? tabs.profileName(m.session) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(pal.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, DS.Space.space4)
        // Clear of the browser window's traffic lights when bound on the left.
        .padding(.top, 30)
        .padding(.bottom, DS.Space.space2)
        .confirmationDialog("Delete the Sidebar Profile \"\(confirmProfileDelete?.name ?? "")\"?",
                            isPresented: Binding(get: { confirmProfileDelete != nil }, set: { if !$0 { confirmProfileDelete = nil } })) {
            Button("Delete Sidebar Profile", role: .destructive) {
                if let p = confirmProfileDelete { animate { lib.change { $0.removeProfile(p.id) } } }
                confirmProfileDelete = nil
            }
        } message: {
            Text("Its favorites and folders are deleted with it. Browser profiles that showed it show another one.")
        }
    }

    @ViewBuilder
    private func profileMenu(match: Match?, profile: SidebarProfile?) -> some View {
        if let m = match, m.certain, let ref = tabs.profileRef(m.session) {
            Section("Show for \(tabs.profileName(m.session) ?? "this profile")") {
                ForEach(lib.library.profiles) { sp in
                    Button { animate { lib.change { $0.link(ref, to: sp.id) } } } label: {
                        if sp.id == profile?.id { Label(sp.name, systemImage: "checkmark") } else { Text(sp.name) }
                    }
                }
            }
            Button("New Sidebar Profile") {
                animate { lib.change { l in
                    let sp = SidebarProfile(name: tabs.profileName(m.session) ?? "Profile \(l.profiles.count + 1)")
                    l.profiles.append(sp)
                    l.link(ref, to: sp.id)
                } }
            }
        } else {
            Text("Waiting to learn this window's browser profile")
        }
        if let p = profile {
            Divider()
            Button("Rename…") { renaming = nil; profileDraft = p.name; renamingProfile = p.id }
            Button("Delete…", role: .destructive) { confirmProfileDelete = p }
                .disabled(lib.library.profiles.count <= 1)
        }
        Divider()
        Button("Sidebar Settings…") { BetterlinkWindow.open(.tabs) }
    }

    private func renameProfile(_ id: UUID) {
        let name = profileDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { lib.change(profile: id) { $0.name = name } }
        renamingProfile = nil
    }

    // MARK: - Favorites

    private func favorites(_ p: SidebarProfile, _ m: Match, _ open: [BrowserTab]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 64), spacing: 6)], spacing: 6) {
            ForEach(p.favorites) { link in
                let tab = m.tab(for: link)
                let isOpen = tab != nil
                Button { openOrSwitch(link, m) } label: {
                    SavedIcon(icons: [link.icon, tab?.favIconUrl], title: link.title)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isOpen ? pal.selected : pal.hover.opacity(0.6)))
                }
                .buttonStyle(PressStyle())
                .onDrag { drag(Self.savedKey(link.id)) }
                .modifier(dropRow(link.id, horizontal: true, canHold: false, p, open) { zone in
                    let i = p.favorites.firstIndex { $0.id == link.id } ?? p.favorites.count
                    return .favorites(zone == .before ? i : i + 1)
                })
                .transition(Motion.pop(reduceMotion))
                .help(link.title)
                .accessibilityLabel(isOpen ? "\(link.title), open" : link.title)
                .contextMenu {
                    heldMenu(link, tab, p, m)
                    moveMenu(link.id, isFolder: false, inFavorites: true, p)
                    Divider()
                    Button("Remove from Favorites") { deleteWithUndo(link.id, link.title, p) }
                }
            }
        }
        .padding(.horizontal, DS.Space.space1)
        .animation(Motion.quick(reduceMotion), value: p.favorites.map(\.id))
        .animation(Motion.quick(reduceMotion), value: open.map(\.url))
        // Drop a tab here to make it a Favorite.
        .frame(minHeight: p.favorites.isEmpty ? 24 : nil)
        .overlay {
            if p.favorites.isEmpty {
                Text("Drag a tab here for a Favorite").font(DS.TextStyle.caption).foregroundStyle(pal.textTertiary)
            }
        }
        // Dropped on the grid's empty space: the end of the Favorites.
        .dropDestination(for: String.self) { keys, _ in
            dragging = nil
            return apply(keys, at: .favorites(p.favorites.count), p, open)
        }
    }

    // MARK: - Folders

    private func node(_ item: SidebarItem, depth: Int, _ p: SidebarProfile, _ m: Match, _ open: [BrowserTab]) -> AnyView {
        switch item {
        case .folder(let f):
            return AnyView(VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: DS.Space.space2) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).frame(width: 10)
                        .rotationEffect(.degrees(f.expanded ? 90 : 0))
                        .foregroundStyle(pal.textTertiary)
                    Image(systemName: "folder").foregroundStyle(pal.textSecondary)
                    nameOrField(f.id, f.name, p)
                    Spacer(minLength: 0)
                }
                .padding(.leading, CGFloat(depth) * 14)
                .rowStyle()
                .onTapGesture { edit(p.id) { $0.toggleExpanded(f.id) } }
                .onDrag { drag(Self.savedKey(f.id)) }
                .modifier(dropRow(f.id, canHold: true, p, open) { zone in spot(for: f.id, zone, p) })
                .accessibilityElement(children: renaming == f.id ? .contain : .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Folder \(f.name), \(f.expanded ? "open" : "closed")")
                .accessibilityAction { edit(p.id) { $0.toggleExpanded(f.id) } }
                .contextMenu {
                    Button("New Folder Inside") { newFolder(in: f.id, p) }
                    Button("Rename") { startRename(f.id, f.name) }
                    moveMenu(f.id, isFolder: true, inFavorites: false, p)
                    Divider()
                    Button("Delete Folder", role: .destructive) {
                        let n = SidebarProfile.links(in: f.items).count + Self.folders(f.items, prefix: "").count
                        if n == 0 { deleteWithUndo(f.id, f.name, p) } else { confirmDelete = (f.id, f.name, n) }
                    }
                }
                if f.expanded {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(f.items) { child in node(child, depth: depth + 1, p, m, open) }
                    }
                    .transition(Motion.reveal(reduceMotion))
                } else {
                    // Closed, it still lists its open items, as Arc and Dia do.
                    ForEach(SidebarProfile.links(in: f.items).filter { m.links.tab(for: $0.id) != nil }) { l in
                        node(.link(l), depth: depth + 1, p, m, open).transition(Motion.reveal(reduceMotion))
                    }
                }
            }
            .clipped())
        case .link(let l):
            let tab = m.tab(for: l)
            // Like Arc: the link's tab has moved on to another page.
            let away = tab != nil && m.links.isAway(l.id)
            return AnyView(HStack(spacing: DS.Space.space2) {
                SavedIcon(icons: [tab?.favIconUrl, l.icon], title: l.title)
                nameOrField(l.id, l.title, p)
                    .foregroundStyle(tab == nil ? pal.textSecondary : pal.text)
                if away, let tab, renaming != l.id {
                    Text("/ \(tab.title.isEmpty ? tab.url : tab.title)")
                        .font(DS.TextStyle.body).lineLimit(1)
                        .foregroundStyle(pal.textTertiary)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 0)
                if away, let tab, m.session.can(.navigate) {
                    Button { backToSaved(l, tab, m) } label: {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .semibold))
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .foregroundStyle(pal.textSecondary)
                    .help("Back to \(l.title)")
                } else if tab != nil {
                    // Open: like Arc, the saved link stands for its tab.
                    Circle().fill(pal.accent).frame(width: 5, height: 5).accessibilityLabel("open")
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 18)
            .rowStyle(selected: tab?.active == true)
            .onTapGesture { openOrSwitch(l, m) }
            .accessibilityElement(children: renaming == l.id ? .contain : .ignore)
            .accessibilityLabel(tab == nil ? l.title : (away ? "\(l.title), open on another page" : "\(l.title), open"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { openOrSwitch(l, m) }
            .onDrag { drag(Self.savedKey(l.id)) }
            .modifier(dropRow(l.id, canHold: false, p, open) { zone in spot(for: l.id, zone, p) })
            .contextMenu {
                Button("Rename") { startRename(l.id, l.title) }
                heldMenu(l, tab, p, m)
                moveMenu(l.id, isFolder: false, inFavorites: false, p)
                Divider()
                Button("Remove", role: .destructive) { deleteWithUndo(l.id, l.title, p) }
            })
        }
    }

    @ViewBuilder
    private func nameOrField(_ id: UUID, _ name: String, _ p: SidebarProfile) -> some View {
        if renaming == id {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain)
                .foregroundStyle(pal.text)
                .font(DS.TextStyle.body)
                .focused($nameFocused)
                .onAppear { nameFocused = true }
                .onSubmit { edit(p.id) { $0.rename(id, to: draftName) }; renaming = nil }
                .onExitCommand { renaming = nil }
        } else {
            Text(name).font(DS.TextStyle.body).lineLimit(1) // color: the caller's, else the sidebar's default
        }
    }

    private func startRename(_ id: UUID, _ name: String) {
        renamingProfile = nil
        draftName = name
        renaming = id
    }

    private func newFolder(in parent: UUID?, _ p: SidebarProfile) {
        var made: UUID?
        edit(p.id) { made = $0.addFolder("New Folder", in: parent) }
        if let made { startRename(made, "New Folder") }
    }

    // MARK: - Drag and drop

    static func savedKey(_ id: UUID) -> String { "betterlink-saved:\(id.uuidString)" }
    static func savedID(_ key: String) -> UUID? {
        key.hasPrefix("betterlink-saved:") ? UUID(uuidString: String(key.dropFirst("betterlink-saved:".count))) : nil
    }

    /// Whether what is being dragged may land at `spot`: only the sidebar's
    /// own drags, and only moves that would happen (review F4).
    private func allowed(_ spot: SidebarProfile.Spot, _ p: SidebarProfile) -> Bool {
        guard let key = dragging else { return false }
        if let id = Self.savedID(key) { return p.canPlace(id, at: spot) }
        return key.hasPrefix("betterlink-tab:")
    }

    /// Starts a drag of `key`, remembering it for the drop targets.
    private func drag(_ key: String) -> NSItemProvider {
        dragging = key
        return NSItemProvider(object: key as NSString)
    }

    /// Where `zone` of the row for `id` puts what is dropped there.
    private func spot(for id: UUID, _ zone: DropZone, _ p: SidebarProfile) -> SidebarProfile.Spot {
        if zone == .into { return .items(parent: id, index: p.children(of: id).count) }
        let parent = p.parent(of: id)
        let i = p.children(of: parent).firstIndex { $0.id == id } ?? p.children(of: parent).count
        return .items(parent: parent, index: zone == .before ? i : i + 1)
    }

    /// Makes a row a drop target with an insertion line.
    private func dropRow(_ id: UUID, horizontal: Bool = false, canHold: Bool, _ p: SidebarProfile, _ open: [BrowserTab],
                         spot: @escaping (DropZone) -> SidebarProfile.Spot) -> some ViewModifier {
        DropRowModifier(id: id, horizontal: horizontal, canHold: canHold, color: pal.accent,
                        size: rowSizes[id] ?? .zero, target: $dropTarget,
                        measured: { rowSizes[id] = $0 },
                        allowed: { zone in allowed(spot(zone), p) }) { keys, zone in
            dragging = nil
            _ = apply(keys, at: spot(zone), p, open)
        }
    }

    /// Dropped strings, in order: a tab is saved there, a favorite, saved link
    /// or folder moves there.
    @discardableResult
    private func apply(_ keys: [String], at spot: SidebarProfile.Spot, _ p: SidebarProfile, _ open: [BrowserTab]) -> Bool {
        var did = false
        var next = spot
        for k in keys {
            var changed = false
            if let t = Self.tab(forDragKey: k, in: open) {
                let at = next, link = Self.saved(t)
                edit(p.id) { let before = $0; $0.insert(link, at: at); changed = $0 != before }
                if changed { holdIfSaved(t, link) }
            } else if let id = Self.savedID(k) {
                let at = next
                edit(p.id) { let before = $0; $0.place(id, at: at); changed = $0 != before }
            }
            guard changed else { continue }
            did = true
            // Several at once keep their order.
            switch next {
            case .favorites(let i): next = .favorites(i + 1)
            case .items(let parent, let i): next = .items(parent: parent, index: i + 1)
            }
        }
        return did
    }

    /// Move Up, Move Down and Move to, for a row's context menu.
    @ViewBuilder
    private func moveMenu(_ id: UUID, isFolder: Bool, inFavorites: Bool, _ p: SidebarProfile) -> some View {
        let parent = inFavorites ? nil : p.parent(of: id)
        let list: [UUID] = inFavorites ? p.favorites.map(\.id) : p.children(of: parent).map(\.id)
        let i = list.firstIndex(of: id) ?? 0
        Button("Move Up") { edit(p.id) { $0.place(id, at: inFavorites ? .favorites(i - 1) : .items(parent: parent, index: i - 1)) } }
            .disabled(i == 0)
        Button("Move Down") { edit(p.id) { $0.place(id, at: inFavorites ? .favorites(i + 2) : .items(parent: parent, index: i + 2)) } }
            .disabled(i >= list.count - 1)
        Menu("Move to…") {
            if !isFolder && !inFavorites {
                Button("Favorites") { edit(p.id) { $0.place(id, at: .favorites(p.favorites.count)) } }
            }
            if inFavorites || parent != nil {
                Button("Top Level") { edit(p.id) { $0.place(id, at: .items(parent: nil, index: p.items.count)) } }
            }
            // Not into itself or its own folders.
            let mine: Set<UUID> = isFolder ? Set(Self.folders(p.children(of: id), prefix: "").map(\.id) + [id]) : []
            ForEach(Self.folders(p.items, prefix: "").filter { !mine.contains($0.id) && $0.id != parent }) { f in
                Button(f.label) { edit(p.id) { $0.place(id, at: .items(parent: f.id, index: p.children(of: f.id).count)) } }
            }
        }
    }

    /// Deletes at once and offers Undo for a few seconds.
    private func deleteWithUndo(_ id: UUID, _ label: String, _ p: SidebarProfile) {
        var removed: SidebarProfile.Removed?
        edit(p.id) { removed = $0.take(id) }
        guard let removed else { return }
        let now = Date()
        withAnimation(Motion.quick(reduceMotion)) { undo = (p.id, removed, label, now) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if undo?.at == now { withAnimation(Motion.quick(reduceMotion)) { undo = nil } }
        }
    }

    private func undoBar(_ u: (profile: UUID, removed: SidebarProfile.Removed, label: String, at: Date)) -> some View {
        HStack(spacing: DS.Space.space2) {
            Text("Deleted \u{201C}\(u.label)\u{201D}").lineLimit(1).foregroundStyle(pal.textSecondary)
            Spacer(minLength: 0)
            Button("Undo") {
                // Just what was deleted, where it was; later changes stay (review F1).
                edit(u.profile) { $0.restore(u.removed) }
                undo = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(pal.text)
            .fontWeight(.semibold)
        }
        .font(DS.TextStyle.caption)
        .padding(.horizontal, DS.Space.space3)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(pal.hover))
        .padding(DS.Space.space2)
        .transition(Motion.reveal(reduceMotion))
    }

    // MARK: - Tabs

    private func newTabField(_ m: Match) -> some View {
        HStack(spacing: DS.Space.space2) {
            Image(systemName: "plus").foregroundStyle(pal.textTertiary)
            TextField("New Tab", text: $newURL)
                .textFieldStyle(.plain)
                .foregroundStyle(pal.text)
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
    private func tabMenu(_ tab: BrowserTab, _ p: SidebarProfile, _ m: Match, _ open: [BrowserTab]) -> some View {
        Button("Add to Favorites") { save(tab, p) { $0.addFavorite($1) } }
        Menu("Save to Folder") {
            ForEach(Self.folders(p.items, prefix: "")) { f in
                Button(f.label) { save(tab, p) { $0.addLink($1, in: f.id) } }
            }
            Button("New Folder…") {
                var made: UUID?
                save(tab, p) {
                    made = $0.addFolder("New Folder")
                    if let made { $0.addLink($1, in: made) }
                }
                if let made { startRename(made, "New Folder") }
            }
        }
        Divider()
        // What the browser's own tab strip offers, for when the sidebar stands
        // in for it. Each shows only when the installed extension can do it.
        Button("Copy Link") { TabsModel.copy(tab.url) }
        if m.session.can(.reload) { Button("Reload") { tabs.reload(tab, in: m.session) } }
        if m.session.can(.duplicate) { Button("Duplicate") { tabs.duplicate(tab, in: m.session) } }
        if m.session.can(.mute) {
            Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tabs.setMuted(!tab.muted, tab, in: m.session) }
        }
        if m.session.can(.newWindow), open.count > 1 {
            Button("Move to New Window") { tabs.moveToNewWindow(tab, in: m.session) }
        }
        Divider()
        Button("Close Tab") { tabs.close(tab, in: m.session) }
        // Only the plain tabs: a saved link's tab is closed from its link.
        let loose = open.filter { !m.links.claimed.contains($0.id) }
        let below = Array(loose.drop { $0.id != tab.id }.dropFirst())
        Button("Close Other Tabs") { tabs.close(loose.filter { $0.id != tab.id }, in: m.session) }
            .disabled(loose.count < 2)
        Button("Close Tabs Below") { tabs.close(below, in: m.session) }
            .disabled(below.isEmpty)
    }

    /// What a saved link's row or Favorite offers for its tab.
    @ViewBuilder
    private func heldMenu(_ l: SavedLink, _ tab: BrowserTab?, _ p: SidebarProfile, _ m: Match) -> some View {
        if let tab {
            if m.links.isAway(l.id) {
                if m.session.can(.navigate) { Button("Back to Saved Page") { backToSaved(l, tab, m) } }
                Button("Save This Page Here") {
                    edit(p.id) { $0.repoint(l.id, to: tab.url, icon: tab.favIconUrl.hasPrefix("data:") ? tab.favIconUrl : nil) }
                    holds.hold(tab, for: l.id, in: m.session)
                }
            }
            Button("Close Tab") { tabs.close(tab, in: m.session) }
        }
        Button("Copy Link") { TabsModel.copy(l.url) }
    }

    /// Sends a link's tab back to the page the link saves.
    private func backToSaved(_ l: SavedLink, _ tab: BrowserTab, _ m: Match) {
        tabs.navigate(tab, to: l.url, in: m.session)
        sidebar.returnFocusToBrowser()
    }

    /// Saves a tab as a new link and makes it that link's tab.
    private func save(_ tab: BrowserTab, _ p: SidebarProfile, _ add: (inout SidebarProfile, SavedLink) -> Void) {
        let link = Self.saved(tab)
        edit(p.id) { add(&$0, link) }
        holdIfSaved(tab, link)
    }

    /// After a save: the tab it came from is the new link's tab from now on
    /// (nothing when the save was refused, such as a Favorite already there).
    private func holdIfSaved(_ tab: BrowserTab, _ link: SavedLink) {
        guard lib.library.allLinkIDs.contains(link.id),
              let s = Self.look(target: sidebar.target, sessions: tabs.sessions).match?.session else { return }
        holds.hold(tab, for: link.id, in: s)
    }

    /// Switches to the saved link's tab when it has one in this window (or in
    /// another window of the same profile), else opens it here. Either way
    /// that tab is the link's from now on, wherever it navigates.
    private func openOrSwitch(_ link: SavedLink, _ m: Match) {
        if let t = m.tab(for: link) {
            holds.hold(t, for: link.id, in: m.session)
            tabs.activate(t, in: m.session)
        } else if let t = elsewhere(link, m) {
            tabs.activate(t, in: m.session)
        } else {
            tabs.open(link, in: m.session, windowId: m.window?.id)
        }
        sidebar.returnFocusToBrowser()
    }

    /// The link's tab in another window of this browser profile: one it holds
    /// there, else one at its address.
    private func elsewhere(_ link: SavedLink, _ m: Match) -> BrowserTab? {
        let all = m.session.store.orderedWindows.flatMap(\.tabs)
        let held = Set(holds.holds(in: m.session).tabs(heldBy: link.id))
        return all.first { held.contains($0.id) } ?? all.first { SavedLink.same($0.url, link.url) }
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

    static func dragKey(_ t: BrowserTab) -> String { "betterlink-tab:\(t.id)" }

    /// A stable row id for a tab, for the drop line.
    static func rowID(_ t: BrowserTab) -> UUID {
        UUID(uuidString: String(format: "7AB00000-0000-0000-0000-%012llX", UInt64(UInt32(truncatingIfNeeded: t.id)))) ?? UUID()
    }

    /// A tab row as a drop target: another tab of this window dropped before or
    /// after it moves there in the browser.
    private func tabDropRow(_ target: BrowserTab, _ m: Match, _ open: [BrowserTab]) -> some ViewModifier {
        let id = Self.rowID(target)
        func dragged() -> BrowserTab? { dragging.flatMap { Self.tab(forDragKey: $0, in: open) } }
        return DropRowModifier(id: id, horizontal: false, canHold: false, color: pal.accent,
                               size: rowSizes[id] ?? .zero, target: $dropTarget,
                               measured: { rowSizes[id] = $0 },
                               allowed: { zone in
                                   guard m.session.can(.move), let t = dragged() else { return false }
                                   return TabMove.index(moving: t.index, nextTo: target.index, after: zone == .after) != nil
                               }) { keys, zone in
            dragging = nil
            guard let t = keys.lazy.compactMap({ Self.tab(forDragKey: $0, in: open) }).first,
                  let to = TabMove.index(moving: t.index, nextTo: target.index, after: zone == .after) else { return }
            tabs.move(t, to: to, in: m.session, windowId: m.window?.id)
        }
    }

    static func tab(forDragKey k: String, in tabs: [BrowserTab]) -> BrowserTab? {
        guard k.hasPrefix("betterlink-tab:"), let id = Int(k.dropFirst("betterlink-tab:".count)) else { return nil }
        return tabs.first { $0.id == id }
    }

    private func emptyText(_ look: Look) -> String {
        guard let t = sidebar.target else { return "" }
        switch look {
        case .window, .connecting:
            return ""
        case .unseen:
            return "betterlink can't see this window's tabs. For an Incognito window, turn on Allow in Incognito for the betterlink Tabs extension in \(t.appName). For another profile, load the extension in that profile too."
        case .notConnected:
            return "Tabs aren't set up for \(t.appName). In betterlink, open Tabs and choose Set Up next to \(t.appName), then load the Tabs extension in it."
        }
    }

    /// Inline icons of open tabs for saved links that have none yet. Not from
    /// a private window, and not from a tab that has moved on to another page.
    static func iconsToLearn(_ p: SidebarProfile?, _ m: Match?) -> [UUID: String] {
        guard let p, let m, !m.incognito, !m.links.tabs.isEmpty else { return [:] }
        var have: [UUID: String] = [:]
        for (link, tab) in m.links.tabs where !m.links.isAway(link) {
            if let icon = m.byId[tab]?.favIconUrl, icon.hasPrefix("data:image/") { have[link] = icon }
        }
        return p.iconsToLearn(from: have)
    }

    struct Match {
        var session: BrowserSession
        var window: TabStore.WindowEntry?
        /// Always true: the window in front is found for certain or not shown
        /// at all (WindowMatch.find).
        var certain = true
        /// Which tab each saved link stands for in this window.
        var links = LinkResolution()
        var byId: [Int: BrowserTab] = [:]

        var incognito: Bool { window?.window.incognito ?? false }

        func tab(for link: SavedLink) -> BrowserTab? { links.tab(for: link.id).flatMap { byId[$0] } }

        /// This match with its saved links resolved against the window's tabs.
        func resolving(_ p: SidebarProfile?, holds: LinkHolds) -> Match {
            var m = self
            let open = window?.tabs ?? []
            m.byId = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            if let p {
                m.links = LinkResolution(links: p.allLinks, tabs: open.map { OpenTab(id: $0.id, url: $0.url) }, holds: holds)
            }
            return m
        }
    }

    /// What the sidebar can show for the window it is bound to.
    enum Look {
        case window(Match)
        /// The browser is connected, but this window isn't one the extension
        /// reports (Incognito without permission, a profile without it).
        case unseen
        /// Connected, with the first list of tabs still on its way.
        case connecting
        case notConnected

        var match: Match? {
            if case .window(let m) = self { return m }
            return nil
        }
    }

    /// The browser session (profile) and window behind the bound window, or
    /// why there is none. Never a guess (see WindowMatch.find): a click here
    /// switches, closes and opens tabs, so the wrong window is worse than none.
    static func look(target: WindowTracker.Target?, sessions: [BrowserSession]) -> Look {
        guard let t = target else { return .notConnected }
        // Each browser profile is its own session. One whose browser process
        // isn't known yet is matched by the browser's name.
        let mine = sessions.filter { $0.browserPid == Int(t.pid) }
        let candidates = mine.isEmpty ? sessions.filter { $0.browser == t.appName } : mine
        let frame = NSScreen.screens.first.map { screen -> WindowBounds in
            let ax = SidebarGeometry.ax(fromCocoa: t.frame, mainScreenHeight: screen.frame.height)
            return WindowBounds(left: ax.minX, top: ax.minY, width: ax.width, height: ax.height)
        }
        switch WindowMatch.find(frame: frame, title: t.title, in: candidates) {
        case .window(let hit):
            guard let s = candidates.first(where: { $0.id == hit.session }) else { return .unseen }
            return .window(Match(session: s, window: s.store.orderedWindows.first { $0.id == hit.windowId }))
        case .notConnected:
            return .notConnected
        case .unseen:
            return candidates.contains { !$0.store.hasSnapshot } ? .connecting : .unseen
        }
    }
}

private struct SidebarTabRow: View {
    let tab: BrowserTab
    /// Whether the installed extension can mute: the speaker is a button then.
    let canMute: Bool
    let activate: () -> Void
    let close: () -> Void
    let mute: () -> Void
    @State private var hovering = false

    @Environment(\.sidebarColors) private var pal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: DS.Space.space2) {
            Favicon(url: tab.favIconUrl)
            Text(tab.title.isEmpty ? tab.url : tab.title)
                .font(DS.TextStyle.body)
                .lineLimit(1)
                .foregroundStyle(pal.text)
            Spacer(minLength: 0)
            if tab.audible || tab.muted {
                // Playing sound, or silenced: click the speaker to mute or unmute.
                let speaker = Image(systemName: tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").font(.caption)
                if canMute {
                    Button(action: mute) { speaker.frame(width: 16, height: 16).contentShape(Rectangle()) }
                        .buttonStyle(PressStyle())
                        .foregroundStyle(pal.textTertiary)
                        .help(tab.muted ? "Unmute tab" : "Mute tab")
                        .accessibilityLabel(tab.muted ? "Unmute \(tab.title)" : "Mute \(tab.title)")
                } else {
                    speaker.foregroundStyle(pal.textTertiary)
                }
            }
            if hovering {
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(PressStyle())
                    .foregroundStyle(pal.textSecondary)
                    .accessibilityLabel("Close \(tab.title)")
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, DS.Space.space2)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tab.active ? pal.selected : (hovering ? pal.hover : .clear))
        )
        .contentShape(Rectangle())
        .animation(Motion.hover(reduceMotion), value: hovering)
        .animation(Motion.quick(reduceMotion), value: tab.active)
        .onHover { hovering = $0 }
        .onTapGesture(perform: activate)
        .accessibilityAddTraits(tab.active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { activate() }
        .accessibilityAction(named: Text("Close")) { close() }
    }
}

private struct RowStyle: ViewModifier {
    var selected: Bool
    @Environment(\.sidebarColors) private var pal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.padding(.horizontal, DS.Space.space2)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? pal.selected : (hovering ? pal.hover : .clear)))
            .contentShape(Rectangle())
            .animation(Motion.hover(reduceMotion), value: hovering)
            .animation(Motion.quick(reduceMotion), value: selected)
            .onHover { hovering = $0 }
    }
}

/// The sidebar's motion: short ease-outs, and none at all with Reduce Motion.
enum Motion {
    static func quick(_ reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: 0.18) }
    static func hover(_ reduce: Bool) -> Animation? { reduce ? nil : .easeOut(duration: 0.12) }
    /// Rows and folder contents: fade and slide down a little.
    static func reveal(_ reduce: Bool) -> AnyTransition {
        reduce ? .identity : .opacity.combined(with: .offset(y: -4))
    }
    /// Favorites: fade and grow from slightly smaller.
    static func pop(_ reduce: Bool) -> AnyTransition {
        reduce ? .identity : .opacity.combined(with: .scale(scale: 0.85))
    }
}

/// Buttons dip slightly while pressed.
struct PressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(Motion.hover(reduceMotion), value: configuration.isPressed)
    }
}

private extension View {
    func rowStyle(selected: Bool = false) -> some View { modifier(RowStyle(selected: selected)) }
}

/// The sidebar's text and fill colors: the standard design tokens, or, on a
/// profile color, the readable palette made for it (SidebarPalette, WCAG AA).
struct SidebarColors {
    var text, textSecondary, textTertiary, hover, selected, accent: Color
    /// On a profile color, the scheme whose system colors read on it: dark for
    /// light text, light for dark text. Nil keeps the app's own appearance.
    var scheme: ColorScheme?

    init(_ p: SidebarPalette?) {
        guard let p else {
            scheme = nil
            text = DS.Palette.text; textSecondary = DS.Palette.textSecondary; textTertiary = DS.Palette.textTertiary
            hover = DS.Palette.hover; selected = DS.Palette.selected; accent = DS.Palette.accent
            return
        }
        func c(_ v: SidebarPalette.RGB, _ a: Double = 1) -> Color { Color(.sRGB, red: v.r, green: v.g, blue: v.b, opacity: a) }
        text = c(p.foreground)
        scheme = p.wantsDarkScheme ? .dark : .light
        textSecondary = c(p.level(SidebarPalette.secondaryOpacity))
        textTertiary = c(p.level(SidebarPalette.tertiaryOpacity))
        hover = c(p.foreground, SidebarPalette.hoverOpacity)
        selected = c(p.foreground, SidebarPalette.selectedOpacity)
        accent = c(p.foreground)
    }
}

/// Sets the color scheme only when there is one to set.
private struct SchemeOverride: ViewModifier {
    var scheme: ColorScheme?
    func body(content: Content) -> some View {
        if let scheme { content.environment(\.colorScheme, scheme) } else { content }
    }
}

private struct SidebarColorsKey: EnvironmentKey {
    static let defaultValue = SidebarColors(nil)
}

extension EnvironmentValues {
    var sidebarColors: SidebarColors {
        get { self[SidebarColorsKey.self] }
        set { self[SidebarColorsKey.self] = newValue }
    }
}
