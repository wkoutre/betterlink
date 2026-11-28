import AppKit
import SwiftUI
import BetterlinkCore
import TabSyncCore

/// What a sidebar panel shows, like Arc's and Dia's sidebars: the Sidebar
/// Profile linked to its window's browser profile (its Favorites grid and
/// folders of saved links), then that window's other open tabs.
struct SidebarView: View {
    /// This window's sidebar. What it shows comes from `sidebar.look`, which
    /// changes only when this window's does: the tab sync itself isn't watched.
    @EnvironmentObject var sidebar: SidebarInstance
    private let tabs = TabsModel.shared
    private var pal: SidebarColors { SidebarColors(sidebar.palette) }
    @ObservedObject private var lib = SidebarLibraryModel.shared
    /// The tabs saved links hold (a saved link keeps its tab as it navigates).
    private let holds = SidebarHoldsModel.shared
    @State private var newURL = ""
    @State private var renaming: UUID?
    /// The folder whose icon is being typed, and which kind.
    @State private var iconEditing: (id: UUID, kind: IconKind)?
    @State private var iconDraft = ""
    @FocusState private var iconFocused: Bool
    @State private var renamingProfile: UUID?
    /// The header's own field: a folder or link rename may be open too (review F2).
    @State private var profileDraft = ""
    /// Naming a new Sidebar Profile in the header, for this browser profile.
    @State private var creatingProfileFor: ProfileRef?
    /// Why the name typed there can't be used yet.
    @State private var profileNameProblem: String?
    @FocusState private var profileNameFocused: Bool
    /// The row a drag is over, and where in it.
    @State private var dropTarget: DropTarget?
    @State private var rowSizes: [UUID: CGSize] = [:]
    /// The last delete, for Undo: which profile, what went and from where.
    @State private var undo: (profile: UUID, removed: [SidebarProfile.Removed], label: String, at: Date)?
    /// Folders with things in them waiting for their delete to be confirmed
    /// (`name`: the folder's, or how many things when several were picked).
    @State private var confirmDelete: (ids: [UUID], name: String)?
    /// The rows picked for one action on all of them: Command-click and
    /// Shift-click, as in Finder (SidebarSelection).
    @State private var selection = SidebarSelection()
    /// What is being dragged from the sidebar, so a row can refuse a drop
    /// that wouldn't move anything (a folder into itself, say).
    @State private var dragging: String?
    /// Which drag that is: one that ends nowhere clears only itself.
    @State private var dragCount = 0
    /// The row the arrow keys are on, while the list has the keyboard.
    @State private var cursor: SidebarRowID?
    @FocusState private var listFocused: Bool
    @FocusState private var newTabFocused: Bool
    /// Gives the New Tab field the keyboard back after a drag swapped it out.
    @State private var dragFocus = DragFocus()
    @State private var downKeyMonitor: Any?
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
        let look = sidebar.look
        let profile = lib.library.profile(for: look.match?.profile?.ref)
        // Which tab each saved link stands for, worked out once for this redraw.
        let match = look.match.map { $0.resolving(profile) }
        let windowTabs = match?.window?.tabs ?? []
        let iconsToLearn = Self.iconsToLearn(profile, match)
        VStack(alignment: .leading, spacing: 0) {
            header(match: match, profile: profile, open: windowTabs)
                // Another profile now: an open rename belonged to the last one.
                .onChange(of: look.match?.profile?.ref) { creatingProfileFor = nil }
                .onChange(of: profile?.id) { renamingProfile = nil; profileNameProblem = nil }
            if let m = match, let profile {
                let loose = windowTabs.filter { !m.links.claimed.contains($0.id) }
                let order = windowTabs.map { RowKey.Place(id: $0.id, pinned: $0.pinned) }
                let rows = SidebarRows.visible(profile, active: m.activeLinks, tabs: loose.map(\.id))
                ScrollViewReader { scroller in
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.space2) {
                            favorites(profile, m, windowTabs)
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(profile.items) { item in
                                    node(item, depth: 0, profile, m, windowTabs).transition(Motion.reveal(reduceMotion))
                                }
                            }
                            // A closed folder shows the active tab when it holds it,
                            // which comes and goes with tabs: animate it in place too (review F1).
                            .animation(Motion.quick(reduceMotion), value: windowTabs.map { [$0.id, $0.active ? 1 : 0] })
                            let end = SidebarProfile.Spot.items(parent: nil, index: profile.items.count)
                            DropSwap(showing: allowed(end, profile), height: DS.Size.sizeRow) {
                                dropZone("Drag here to save", at: end, profile, windowTabs)
                            } line: {
                                newTabField(m)
                            }
                            LazyVStack(alignment: .leading, spacing: 1) {
                                // Tabs that are open saved links show in their folder instead.
                                ForEach(loose) { tab in
                                    SkipUnchanged(key: rowKey(tab, profile, m, order)) {
                                        SidebarTabRow(tab: tab, title: sidebar.title(of: tab), canMute: m.session.can(.mute),
                                                      focused: isCursor(.tab(tab.id)), picked: selection.contains(.tab(tab.id))) {
                                            click(.tab(tab.id)) {
                                                tabs.activate(tab, in: m.session)
                                                sidebar.returnFocusToBrowser()
                                            }
                                        } close: {
                                            tabs.close(tab, in: m.session)
                                        } mute: {
                                            tabs.setMuted(!tab.muted, tab, in: m.session)
                                        }
                                        .onDrag { drag(dragKey(.tab(tab.id))) }
                                        // Drop a tab before or after another to reorder the window's tabs.
                                        .modifier(tabDropRow(tab, m, windowTabs))
                                        .contextMenu {
                                            if let n = severalPicked(with: .tab(tab.id)) { bulkMenu(n) } else { tabMenu(tab, profile, m, windowTabs) }
                                        }
                                    }
                                    .equatable()
                                    .id(SidebarRowID.tab(tab.id))
                                    .transition(Motion.reveal(reduceMotion))
                                }
                            }
                            // Tabs opening, closing, moving and switching animate in place.
                            .animation(Motion.quick(reduceMotion), value: windowTabs.map { [$0.id, $0.active ? 1 : 0] })
                        }
                        .padding(.horizontal, DS.Space.space2)
                        .padding(.bottom, DS.Space.space4)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .contextMenu { Button("New Folder") { newFolder(in: nil, profile) } }
                    }
                    // One stop for the keyboard: the arrows move the cursor
                    // through the rows, Return opens, Delete closes or removes.
                    // Beside the rows, not around them: a container's focus is
                    // also on while a field inside it has the keyboard, and the
                    // keys typed there would act on the rows.
                    .background {
                        Color.clear
                            .focusable()
                            .focusEffectDisabled()
                            .focused($listFocused)
                            .onKeyPress(phases: [.down, .repeat]) { key($0, rows, profile, m) }
                            .accessibilityHidden(true)
                    }
                    .onChange(of: listFocused) { _, on in
                        cursor = on ? cursor ?? rows.first : nil
                    }
                    .onChange(of: rows) { old, new in
                        cursor = SidebarRows.keep(cursor, from: old, to: new)
                        // A picked row that is gone (its tab closed, its folder closed over it) is no longer picked.
                        let kept = selection.kept(in: new)
                        if kept != selection { selection = kept }
                    }
                    .onChange(of: cursor) { _, c in if let c { scroller.scrollTo(c) } }
                }
            } else {
                emptyState(look)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: sidebar.placedSide == .right ? .leading : .trailing) { ResizeHandle(sidebar: sidebar) }
        // The drag is over, dropped or not: the New Tab field has the keyboard
        // again if it had it when the drag began.
        .onChange(of: dragging) { _, now in
            guard now == nil else { return }
            let owed = dragFocus.ended(hasKeyboard: newTabHasKeyboard)
            DragTrace.log("drag: ended, New Tab owed the keyboard \(owed) (\(newTabTrace))")
            // Not set here: the field may not be back yet (its onAppear sets it).
            if owed { retryNewTabFocus("drag ended") }
        }
        // At the bottom: what is picked, with the actions on all of it, and
        // Undo for the last delete, for a few seconds.
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                if !selection.isEmpty, let n = now() { selectionBar(n) }
                if let u = undo { undoBar(u) }
            }
        }
        // A folder with things in it asks first (review F6), then offers Undo too.
        .confirmationDialog(confirmDelete.map { $0.ids.count == 1 ? "Delete \"\($0.name)\" and everything in it?"
                                                                  : "Delete \($0.name), with everything in the folders?" } ?? "",
                            isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button(confirmDelete?.ids.count == 1 ? "Delete Folder" : "Delete", role: .destructive) {
                if let d = confirmDelete, let p = profile {
                    deleteWithUndo(d.ids, d.name, p)
                    animate { selection.clear() }
                }
                confirmDelete = nil
            }
        }
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

    /// The height of a window's title bar: the header starts below the browser
    /// window's traffic lights when bound on the left.
    private static let titleBarHeight = NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height

    private func header(match: Match?, profile: SidebarProfile?, open: [BrowserTab]) -> some View {
        // Until there is a Favorite, dropping one here makes the first.
        let first = profile.flatMap { $0.favorites.isEmpty && match != nil && allowed(.favorites(0), $0) ? $0 : nil }
        return DropSwap(showing: first != nil, height: 24) {
            if let first { dropZone("Drag here for a Favorite", at: .favorites(0), first, open) }
        } line: {
            headerLine(match: match, profile: profile)
        }
        .padding(.horizontal, DS.Space.space4)
        .padding(.top, Self.titleBarHeight)
        .padding(.bottom, DS.Space.space2)
        .confirmationDialog("Delete the Sidebar Profile \"\(confirmProfileDelete?.name ?? "")\"?",
                            isPresented: Binding(get: { confirmProfileDelete != nil }, set: { if !$0 { confirmProfileDelete = nil } })) {
            Button("Delete Sidebar Profile", role: .destructive) {
                if let p = confirmProfileDelete { animate { lib.change { $0.removeProfile(p.id) } } }
                confirmProfileDelete = nil
            }
        } message: {
            Text("Its Favorites and folders are deleted with it. Browser Profiles that showed it show another one.")
        }
    }

    private func headerLine(match: Match?, profile: SidebarProfile?) -> some View {
        let known = match?.profile != nil
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: DS.Space.space1) { headerRow(match: match, profile: profile, known: known) }
            if let problem = profileNameProblem, creatingProfileFor != nil || renamingProfile != nil {
                // The sidebar's own colors: its tint can be any profile color.
                Label(problem, systemImage: "exclamationmark.circle").font(DS.TextStyle.caption).foregroundStyle(pal.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func headerRow(match: Match?, profile: SidebarProfile?, known: Bool) -> some View {
            if let ref = creatingProfileFor {
                TextField("New Sidebar Profile name", text: $profileDraft)
                    .textFieldStyle(.plain)
                    .font(DS.TextStyle.headline)
                    .foregroundStyle(pal.text)
                    .focused($profileNameFocused)
                    .onAppear { profileNameFocused = true }
                    .onChange(of: profileDraft) { profileNameProblem = nil }
                    .onSubmit { createProfile(for: ref) }
                    .onExitCommand { creatingProfileFor = nil; profileNameProblem = nil }
                    .accessibilityLabel("New Sidebar Profile name")
            } else if let p = profile, renamingProfile == p.id {
                TextField("Name", text: $profileDraft)
                    .textFieldStyle(.plain)
                    .font(DS.TextStyle.headline)
                    .foregroundStyle(pal.text)
                    .focused($profileNameFocused)
                    .onAppear { profileNameFocused = true }
                    .onChange(of: profileDraft) { profileNameProblem = nil }
                    .onSubmit { renameProfile(p.id) }
                    .onExitCommand { renamingProfile = nil; profileNameProblem = nil }
            } else {
                Text(profile?.name ?? "Sidebar")
                    .font(DS.TextStyle.headline)
                    .foregroundStyle(pal.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Needs no Browser Profile, so it works before the window's is known.
            Button { FindTabPanel.shared.show() } label: { headerIcon("magnifyingglass") }
                .buttonStyle(PressStyle())
                .help("Find a Tab (\(SidebarController.shared.findShortcut.display))")
                .accessibilityLabel("Find a Tab")
            Button { if let p = profile { newFolder(in: nil, p) } } label: { headerIcon("plus") }
                .buttonStyle(PressStyle())
                .disabled(match == nil || profile == nil)
                .help("New Folder")
                .accessibilityLabel("New Folder")
            // The Sidebar Profile's settings: which one this Browser Profile
            // shows, a new one, rename, delete, and the sidebar's settings page.
            Menu {
                profileMenu(match: match, profile: profile)
            } label: {
                headerIcon("gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!known)
            .help(known ? "Sidebar Profile settings" : "Waiting to learn this window's Browser Profile")
            .accessibilityLabel("Sidebar Profile settings")
    }

    private func headerIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(DS.TextStyle.body)
            .foregroundStyle(pal.textSecondary)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private func profileMenu(match: Match?, profile: SidebarProfile?) -> some View {
        if let m = match, let known = m.profile {
            Section("Show for \(m.session.browser) · \(known.name)") {
                ForEach(lib.library.profiles) { sp in
                    Button { animate { lib.change { $0.link(known.ref, to: sp.id) } } } label: {
                        if sp.id == profile?.id { Label(sp.name, systemImage: "checkmark") } else { Text(sp.name) }
                    }
                }
            }
            Button("New Sidebar Profile…") {
                renaming = nil; iconEditing = nil; renamingProfile = nil; profileNameProblem = nil
                profileDraft = ""; creatingProfileFor = known.ref
            }
        }
        if let p = profile {
            Divider()
            Button("Rename…") { renaming = nil; iconEditing = nil; profileDraft = p.name; renamingProfile = p.id }
            Button("Delete…", role: .destructive) { confirmProfileDelete = p }
                .disabled(lib.library.profiles.count <= 1)
        }
        Divider()
        Button("Sidebar Settings…") { BetterlinkWindow.open(.sidebar) }
    }

    private func renameProfile(_ id: UUID) {
        let name = profileDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unchanged or emptied: nothing to do. A name another profile has stays open to change.
        if !name.isEmpty, lib.library.profiles.first(where: { $0.id == id })?.name != name {
            if let problem = lib.library.nameProblem(name, except: id) { profileNameProblem = problem; return }
            lib.change(profile: id) { $0.name = name }
        }
        profileNameProblem = nil
        renamingProfile = nil
    }

    /// Makes the Sidebar Profile named in the header and shows it for `ref`.
    private func createProfile(for ref: ProfileRef) {
        if let problem = lib.library.nameProblem(profileDraft) { profileNameProblem = problem; return }
        animate { lib.change { _ = $0.addProfile(named: profileDraft, showingFor: ref) } }
        profileNameProblem = nil
        creatingProfileFor = nil
    }

    // MARK: - Favorites

    @ViewBuilder
    private func favorites(_ p: SidebarProfile, _ m: Match, _ open: [BrowserTab]) -> some View {
        // With none, the header turns into the place to drop the first.
        if !p.favorites.isEmpty { favoritesGrid(p, m, open) }
    }

    /// Somewhere to drop what is being dragged (see DropSwap).
    private func dropZone(_ text: String, at spot: SidebarProfile.Spot, _ p: SidebarProfile, _ open: [BrowserTab]) -> some View {
        Text(text)
            .font(DS.TextStyle.caption)
            .foregroundStyle(pal.textTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: DS.Radius.radiusSm, style: .continuous)
                .strokeBorder(pal.textTertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
            .onDrop(of: [SidebarDrag.type], isTargeted: nil) { drop($0, at: spot, p, open) }
    }

    /// A drop on a zone or on the Favorites' empty space. The keys arrive
    /// later, so whether it is taken is decided from what this sidebar is
    /// dragging: a drop that would move nothing (a folder onto the Favorites)
    /// is refused, and slides back. Not known here: a tab whose page is already
    /// a Favorite counts as taken and saves nothing, and a row dragged from
    /// another window's sidebar is taken as it was before.
    private func drop(_ providers: [NSItemProvider], at spot: SidebarProfile.Spot, _ p: SidebarProfile, _ open: [BrowserTab]) -> Bool {
        guard dragging == nil || allowed(spot, p) else {
            dragging = nil
            return false
        }
        SidebarDrag.keys(from: providers) { keys in
            dragging = nil
            apply(keys, at: spot, p, open)
        }
        return true
    }

    private func favoritesGrid(_ p: SidebarProfile, _ m: Match, _ open: [BrowserTab]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 64), spacing: 6)], spacing: 6) {
            ForEach(p.favorites) { link in
                let tab = m.tab(for: link)
                let isOpen = tab != nil
                let picked = selection.contains(.favorite(link.id))
                Button { click(.favorite(link.id)) { openOrSwitch(link, m) } } label: {
                    SavedIcon(icons: [link.icon, tab?.favIconUrl], title: link.title)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.radiusMd, style: .continuous)
                            .fill(isOpen || picked ? pal.selected : pal.hover.opacity(0.6)))
                        .modifier(FocusRing(on: isCursor(.favorite(link.id)), radius: DS.Radius.radiusMd))
                }
                .buttonStyle(PressStyle())
                // Picked with others for one action: a check on the tile's other corner.
                .overlay(alignment: .topLeading) {
                    if picked { PickedMark().offset(x: -2, y: -2).transition(Motion.pop(reduceMotion)) }
                }
                // Its tab plays sound (or is silenced): the speaker sits on the
                // tile's corner, a button of its own.
                .overlay(alignment: .topTrailing) {
                    if let tab {
                        TabSpeaker(tab: tab, name: link.title, canMute: m.session.can(.mute), onTile: true) {
                            tabs.setMuted(!tab.muted, tab, in: m.session)
                        }
                        .offset(x: 2, y: -2)
                    }
                }
                .id(SidebarRowID.favorite(link.id))
                .onDrag { drag(dragKey(.favorite(link.id))) }
                .modifier(dropRow(link.id, horizontal: true, canHold: false, p, open) { zone in
                    let i = p.favorites.firstIndex { $0.id == link.id } ?? p.favorites.count
                    return .favorites(zone == .before ? i : i + 1)
                })
                .transition(Motion.pop(reduceMotion))
                .help(link.title)
                .accessibilityLabel(isOpen ? "\(link.title), open" : link.title)
                .accessibilityAddTraits(picked ? .isSelected : [])
                .contextMenu {
                    if let n = severalPicked(with: .favorite(link.id)) {
                        bulkMenu(n)
                    } else {
                        heldMenu(link, tab, p, m)
                        moveMenu(link.id, isFolder: false, inFavorites: true, p)
                        Divider()
                        Button("Remove from Favorites") { deleteWithUndo(link.id, link.title, p) }
                    }
                }
            }
        }
        .padding(.horizontal, DS.Space.space1)
        .animation(Motion.quick(reduceMotion), value: p.favorites.map(\.id))
        .animation(Motion.quick(reduceMotion), value: open.map(\.url))
        // Dropped on the grid's empty space: the end of the Favorites.
        .onDrop(of: [SidebarDrag.type], isTargeted: nil) { drop($0, at: .favorites(p.favorites.count), p, open) }
    }

    // MARK: - Folders

    private func node(_ item: SidebarItem, depth: Int, _ p: SidebarProfile, _ m: Match, _ open: [BrowserTab]) -> AnyView {
        switch item {
        case .folder(let f):
            return AnyView(VStack(alignment: .leading, spacing: 1) {
                SidebarRow(indent: CGFloat(depth) * Self.indent, focused: isCursor(.folder(f.id)),
                           picked: selection.contains(.folder(f.id)),
                           editing: renaming == f.id || iconEditing?.id == f.id,
                           label: "Folder \(f.name), \(f.expanded ? "open" : "closed")") {
                    // Command and Shift pick the folder; Option alone opens or closes every folder.
                    click(.folder(f.id)) { toggleFolder(f, all: NSEvent.modifierFlags.contains(.option), p) }
                } content: {
                    if let editing = iconEditing, editing.id == f.id {
                        iconField(f, editing.kind, p)
                    } else {
                        FolderGlyph(icon: f.icon, expanded: f.expanded)
                        nameOrField(f.id, f.name, p)
                    }
                }
                .id(SidebarRowID.folder(f.id))
                .onDrag { drag(dragKey(.folder(f.id))) }
                .modifier(dropRow(f.id, canHold: true, p, open) { zone in spot(for: f.id, zone, p) })
                .contextMenu {
                    if let n = severalPicked(with: .folder(f.id)) {
                        bulkMenu(n)
                    } else {
                        Button("New Folder Inside") { newFolder(in: f.id, p) }
                        Button("Rename") { startRename(f.id, f.name) }
                        iconMenu(f, p)
                        moveMenu(f.id, isFolder: true, inFavorites: false, p)
                        Divider()
                        Button("Delete Folder", role: .destructive) { deleteFolder(f, p) }
                    }
                }
                if let editing = iconEditing, editing.id == f.id, editing.kind == .emoji {
                    emojiGrid(f, p, indent: CGFloat(depth) * Self.indent)
                        .transition(Motion.reveal(reduceMotion))
                }
                if f.expanded {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(f.items) { child in node(child, depth: depth + 1, p, m, open) }
                    }
                    .transition(Motion.reveal(reduceMotion))
                } else {
                    // Closed, it still shows the tab you are on when that tab is
                    // inside it, as Dia does; its other tabs fold away with it.
                    ForEach(SidebarRows.peek(f, active: m.activeLinks)) { l in
                        node(.link(l), depth: depth + 1, p, m, open).transition(Motion.reveal(reduceMotion))
                    }
                }
            }
            .clipped())
        case .link(let l):
            let tab = m.tab(for: l)
            // Like Arc: the link's tab has moved on to another page.
            let away = tab != nil && m.links.isAway(l.id)
            return AnyView(SidebarRow(indent: CGFloat(depth) * Self.indent, selected: tab?.active == true,
                                      focused: isCursor(.link(l.id)), picked: selection.contains(.link(l.id)),
                                      editing: renaming == l.id,
                                      label: tab == nil ? l.title : (away ? "\(l.title), open on another page" : "\(l.title), open")) {
                click(.link(l.id)) { openOrSwitch(l, m) }
            } content: {
                SavedIcon(icons: [tab?.favIconUrl, l.icon], title: l.title)
                // Dim while closed, full strength while open.
                nameOrField(l.id, l.title, p)
                    .foregroundStyle(tab == nil ? pal.textSecondary : pal.text)
                if away, let tab, renaming != l.id {
                    TabTitleText(title: sidebar.title(of: tab), url: tab.url, before: "/ ")
                        .font(DS.TextStyle.body).lineLimit(1)
                        .foregroundStyle(pal.textTertiary)
                        .layoutPriority(-1)
                }
            } trailing: {
                if let tab {
                    TabSpeaker(tab: tab, name: l.title, canMute: m.session.can(.mute)) {
                        tabs.setMuted(!tab.muted, tab, in: m.session)
                    }
                }
                if away, let tab, m.session.can(.navigate) {
                    Button { backToSaved(l, tab, m) } label: { RowIcon("arrow.uturn.backward") }
                        .buttonStyle(PressStyle())
                        .foregroundStyle(pal.textSecondary)
                        .help("Back to \(l.title)")
                        .accessibilityLabel("Back to \(l.title)")
                }
            }
            .id(SidebarRowID.link(l.id))
            .onDrag { drag(dragKey(.link(l.id))) }
            .modifier(dropRow(l.id, canHold: false, p, open) { zone in spot(for: l.id, zone, p) })
            .contextMenu {
                if let n = severalPicked(with: .link(l.id)) {
                    bulkMenu(n)
                } else {
                    Button("Rename") { startRename(l.id, l.title) }
                    Button("New Folder") { newFolder(in: p.parent(of: l.id), p) }
                    heldMenu(l, tab, p, m)
                    moveMenu(l.id, isFolder: false, inFavorites: false, p)
                    Divider()
                    Button("Remove", role: .destructive) { deleteWithUndo(l.id, l.title, p) }
                }
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
        iconEditing = nil
        draftName = name
        renaming = id
    }

    // MARK: - Folder icons

    enum IconKind { case emoji, symbol }

    /// Icon in a folder's menu: an emoji, a built-in symbol, or the folder
    /// glyph again. Each is typed in the row, as a rename is.
    private func iconMenu(_ f: SidebarFolder, _ p: SidebarProfile) -> some View {
        Menu("Icon") {
            Button("Choose Emoji…") { startIcon(f, .emoji) }
            Button("Choose Symbol…") { startIcon(f, .symbol) }
            if f.icon != nil {
                Divider()
                Button("Remove Icon") { edit(p.id) { $0.setIcon(f.id, to: nil) } }
            }
        }
    }

    private func startIcon(_ f: SidebarFolder, _ kind: IconKind) {
        renaming = nil
        renamingProfile = nil
        // A symbol's name starts as the one it has, to change a little; an
        // emoji starts empty, so the one typed is the only one there.
        if kind == .symbol, case .symbol(let name)? = f.icon { iconDraft = name } else { iconDraft = "" }
        // Unset first: SwiftUI moves the keyboard only when the focus changes,
        // and a field left from the last icon may still count as focused.
        iconFocused = false
        animate { iconEditing = (f.id, kind) }
    }

    private func endIcon() {
        iconFocused = false
        animate { iconEditing = nil }
    }

    /// Gives the icon field the keyboard as it opens, as Rename's field takes
    /// it. Opened from the Icon submenu, the first try was seen to miss (on
    /// screen, typing reached the field only after a click), so it is tried
    /// again a turn later and once the menu has closed, making the panel key
    /// when it isn't. The panel never activates betterlink, so the browser
    /// stays the active app.
    private func focusIconField() {
        func attempt(last: Bool) {
            guard iconEditing != nil else { return }
            if let panel = sidebar.panel, !panel.isKeyWindow { panel.makeKey() }
            if !iconFocused {
                iconFocused = true
            } else if last, !(sidebar.panel?.firstResponder is NSTextView) {
                // Set, and it did not take: SwiftUI moves the focus only on a change.
                iconFocused = false
                DispatchQueue.main.async { iconFocused = true }
            }
        }
        attempt(last: false)
        DispatchQueue.main.async { attempt(last: false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { attempt(last: true) }
    }

    /// What `iconDraft` would set, or nil while it isn't one yet.
    private func draftIcon(_ kind: IconKind) -> FolderIcon? {
        switch kind {
        case .emoji: return try? FolderIcon.checkedEmoji(iconDraft)
        case .symbol: return try? FolderIcon.checkedSymbol(iconDraft, exists: SymbolCheck.exists)
        }
    }

    /// The row while its icon is typed: a preview where the icon goes, then
    /// the field. An emoji is set as soon as one is typed or pasted, or
    /// clicked in the grid below the row; a symbol's name is set with Return,
    /// once the preview shows it. Esc leaves the icon as it was.
    @ViewBuilder
    private func iconField(_ f: SidebarFolder, _ kind: IconKind, _ p: SidebarProfile) -> some View {
        let draft = draftIcon(kind)
        Group {
            if let draft { FolderGlyph(icon: draft, expanded: f.expanded) }
            else {
                Image(systemName: "questionmark.square.dashed").foregroundStyle(pal.textTertiary).frame(width: 16)
                    .accessibilityHidden(true)
            }
        }
        TextField(kind == .emoji ? "Emoji" : "Symbol name, such as star.fill", text: $iconDraft)
            .textFieldStyle(.plain)
            .foregroundStyle(pal.text)
            .font(DS.TextStyle.body)
            .focused($iconFocused)
            .accessibilityLabel(kind == .emoji ? "Emoji for \(f.name)" : "Symbol name for \(f.name)")
            // A field of its own for each kind, so switching kinds opens it afresh.
            .id(kind)
            .onAppear { focusIconField() }
            .onChange(of: iconDraft) { _, _ in
                if kind == .emoji, let icon = draftIcon(.emoji) { setIcon(f.id, icon, p) }
            }
            .onSubmit {
                if let icon = draftIcon(kind) { setIcon(f.id, icon, p) } else { NSSound.beep() }
            }
            .onExitCommand { endIcon() }
    }

    /// Under a row choosing an emoji: common ones to click. The Mac's emoji
    /// picker opens only for the active app's field, and this panel never
    /// makes betterlink the active app (opening it brought another app
    /// forward instead), so the sidebar offers its own; any other emoji can
    /// be typed or pasted into the field.
    private func emojiGrid(_ f: SidebarFolder, _ p: SidebarProfile, indent: CGFloat) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 26, maximum: 30), spacing: 2)], spacing: 2) {
            ForEach(FolderIcon.suggestedEmoji, id: \.self) { e in
                Button { setIcon(f.id, .emoji(e), p) } label: {
                    Text(e).font(DS.TextStyle.body).frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(e)
                .accessibilityLabel(e)
            }
        }
        .padding(.leading, DS.Space.space2 + indent)
        .padding(.trailing, DS.Space.space2)
        .padding(.vertical, DS.Space.space1)
    }

    private func setIcon(_ id: UUID, _ icon: FolderIcon, _ p: SidebarProfile) {
        edit(p.id) { $0.setIcon(id, to: icon) }
        endIcon()
    }

    private func newFolder(in parent: UUID?, _ p: SidebarProfile) {
        var made: UUID?
        edit(p.id) { made = $0.addFolder("New Folder", in: parent) }
        if let made { startRename(made, "New Folder") }
    }

    private func deleteFolder(_ f: SidebarFolder, _ p: SidebarProfile) {
        if f.items.isEmpty { deleteWithUndo(f.id, f.name, p) } else { confirmDelete = ([f.id], f.name) }
    }

    /// How far each level of folders is set in.
    private static let indent: CGFloat = DS.Space.space4

    // MARK: - Unchanged rows

    private func rowKey(_ tab: BrowserTab, _ p: SidebarProfile, _ m: Match, _ order: [RowKey.Place]) -> RowKey {
        let id = Self.rowID(tab)
        return RowKey(tab: tab, order: order, claimed: m.links.claimed, session: m.session.socketPath, ops: m.session.ops,
                      window: m.window?.id, profile: p, focused: isCursor(.tab(tab.id)),
                      picked: selection.contains(.tab(tab.id)) ? selection : nil,
                      drop: dropTarget?.id == id ? dropTarget?.zone : nil, size: rowSizes[id], palette: sidebar.palette,
                      reduceMotion: reduceMotion)
    }

    // MARK: - Keyboard

    private func isCursor(_ row: SidebarRowID) -> Bool { listFocused && cursor == row }

    private func key(_ press: KeyPress, _ rows: [SidebarRowID], _ p: SidebarProfile, _ m: Match) -> KeyPress.Result {
        guard listFocused, press.modifiers.isDisjoint(with: [.command, .control]) else { return .ignored }
        // Option-Left and Option-Right close and open every folder, as Option-click does.
        if press.modifiers.contains(.option) {
            guard press.key == .leftArrow || press.key == .rightArrow else { return .ignored }
            edit(p.id) { $0.setAllExpanded(press.key == .rightArrow) }
            return .handled
        }
        switch press.key {
        case .downArrow, .upArrow:
            let to = SidebarRows.move(cursor, by: press.key == .downArrow ? 1 : -1, in: rows)
            // With Shift, the rows passed over are picked, as in Finder: the
            // range starts at the row the cursor was on.
            if press.modifiers.contains(.shift), let to {
                animate {
                    if selection.isEmpty, let from = cursor { selection.click(from) }
                    selection.extend(to: to, current: nil, in: rows)
                }
            }
            cursor = to
        case .leftArrow, .rightArrow:
            let opening = press.key == .rightArrow
            switch cursor {
            case .folder(let id)?:
                if case .folder(let f)? = SidebarProfile.find(id, in: p.items), f.expanded != opening { edit(p.id) { $0.toggleExpanded(id) } }
            case .favorite?: cursor = SidebarRows.move(cursor, by: opening ? 1 : -1, in: rows)
            default: return .ignored
            }
        case .escape:
            // First what is picked, then the keyboard.
            if !selection.isEmpty { animate { selection.clear() }; return .handled }
            listFocused = false
            sidebar.returnFocusToBrowser()
        // Held down, these must not open or close row after row.
        case .return where press.phase == .down: openCursor(p, m)
        // The Delete key types U+007F; KeyEquivalent.delete is U+0008.
        case .delete where press.phase == .down, "\u{7F}" where press.phase == .down, .deleteForward where press.phase == .down:
            if selection.count > 1 { bulkDelete() } else { deleteCursor(p, m) }
        default: return .ignored
        }
        return .handled
    }

    /// Opens or closes a folder. With Option held (`all`), every folder in the
    /// Sidebar Profile goes the way this one goes, as in Finder and Dia.
    private func toggleFolder(_ f: SidebarFolder, all: Bool, _ p: SidebarProfile) {
        edit(p.id) { profile in
            if all { profile.setAllExpanded(!f.expanded) } else { profile.toggleExpanded(f.id) }
        }
    }

    private func openCursor(_ p: SidebarProfile, _ m: Match) {
        switch cursor {
        case .folder(let id)?: edit(p.id) { $0.toggleExpanded(id) }
        case .favorite(let id)?, .link(let id)?:
            listFocused = false
            if let l = p.savedLink(id) { openOrSwitch(l, m) }
        case .tab(let id)?:
            listFocused = false
            if let t = m.byId[id] { tabs.activate(t, in: m.session); sidebar.returnFocusToBrowser() }
        case nil: break
        }
    }

    /// Closes the row's tab; a saved link with none is removed, and a folder deleted.
    private func deleteCursor(_ p: SidebarProfile, _ m: Match) {
        switch cursor {
        case .folder(let id)?: if case .folder(let f)? = SidebarProfile.find(id, in: p.items) { deleteFolder(f, p) }
        case .favorite(let id)?, .link(let id)?:
            guard let l = p.savedLink(id) else { return }
            if let t = m.tab(for: l) { tabs.close(t, in: m.session) } else { deleteWithUndo(id, l.title, p) }
        case .tab(let id)?: if let t = m.byId[id] { tabs.close(t, in: m.session) }
        case nil: break
        }
    }

    // MARK: - Several rows at once

    /// The sidebar as it is this moment. A click, a menu and a drag read it
    /// when they run: a tab's row keeps its closures while it isn't drawn
    /// again (SkipUnchanged), and what they saw then may be gone.
    private struct Now {
        var profile: SidebarProfile
        var match: Match
        /// The rows on screen, top to bottom.
        var rows: [SidebarRowID]
        /// The row of the tab the window shows.
        var current: SidebarRowID?
    }

    private func now() -> Now? {
        let look = sidebar.look
        guard let found = look.match, let profile = lib.library.profile(for: found.profile?.ref) else { return nil }
        let m = found.resolving(profile)
        let open = m.window?.tabs ?? []
        let rows = SidebarRows.visible(profile, active: m.activeLinks,
                                       tabs: open.filter { !m.links.claimed.contains($0.id) }.map(\.id))
        let current = SidebarRows.current(in: rows, activeTab: open.first(where: \.active)?.id, activeLinks: m.activeLinks)
        return Now(profile: profile, match: m, rows: rows, current: current)
    }

    /// A click on a row. Plain, it does what the row does (`plain`) and
    /// nothing stays picked. With Command held the row joins the picked rows
    /// or leaves them; with Shift every row from the one last clicked to
    /// this one is picked, as in Finder. Neither opens anything.
    private func click(_ row: SidebarRowID, plain: () -> Void) {
        let keys = NSEvent.modifierFlags
        guard keys.contains(.command) || keys.contains(.shift) else {
            if !selection.isEmpty { animate { selection.click(row) } } else { selection.click(row) }
            plain()
            return
        }
        guard let n = now() else { return }
        animate {
            if keys.contains(.command) {
                selection.toggle(row, current: n.current, in: n.rows)
            } else {
                selection.extend(to: row, current: n.current, in: n.rows)
            }
        }
    }

    /// The sidebar now, when `row` is one of several picked rows: its menu
    /// is then the one for all of them.
    private func severalPicked(with row: SidebarRowID) -> Now? {
        selection.count > 1 && selection.contains(row) ? now() : nil
    }

    /// What is picked, and the tabs that are open behind it: the picked tabs
    /// themselves and the tabs of the picked saved links.
    private func pickedThings(_ n: Now) -> (parts: SidebarSelection.Parts, open: [BrowserTab], closed: [SavedLink]) {
        let parts = selection.parts(in: n.rows, of: n.profile)
        let open = parts.tabs.compactMap { n.match.byId[$0] } + parts.links.compactMap { n.match.tab(for: $0) }
        return (parts, open, parts.links.filter { n.match.tab(for: $0) == nil })
    }

    private static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

    /// At the bottom while rows are picked: how many, the actions on all of
    /// them, and a way to pick nothing again.
    private func selectionBar(_ n: Now) -> some View {
        HStack(spacing: DS.Space.space2) {
            Text("\(selection.count) selected").lineLimit(1).foregroundStyle(pal.textSecondary)
            Spacer(minLength: 0)
            Menu {
                bulkMenu(n)
            } label: {
                Text("Actions").fontWeight(.semibold).foregroundStyle(pal.text)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("What to do with the selected rows")
            .accessibilityLabel("Actions for the selected rows")
            Button { animate { selection.clear() } } label: { RowIcon("xmark") }
                .buttonStyle(PressStyle())
                .foregroundStyle(pal.textSecondary)
                .help("Deselect All")
                .accessibilityLabel("Deselect All")
        }
        .font(DS.TextStyle.caption)
        .padding(.leading, DS.Space.space3)
        .padding(.trailing, DS.Space.space1)
        .padding(.vertical, DS.Space.space1)
        .background(RoundedRectangle(cornerRadius: DS.Radius.radiusMd, style: .continuous).fill(pal.hover))
        .padding(DS.Space.space2)
        .transition(Motion.reveal(reduceMotion))
    }

    /// The menu for several picked rows, on any of them and in the bar at
    /// the bottom. Each action works out what is picked again when it runs.
    @ViewBuilder
    private func bulkMenu(_ n: Now) -> some View {
        let things = pickedThings(n)
        let parts = things.parts, open = things.open, closed = things.closed
        let p = n.profile, s = n.match.session
        // Folders stay out of the grid, and so does what is a Favorite already.
        let favorites = Set(p.favorites.map(\.id))
        let canFavorite = !parts.tabs.isEmpty || parts.saved.contains { !favorites.contains($0) && p.folder($0) == nil }
        // Not into a picked folder or one inside it.
        let inside: Set<UUID> = Set(parts.saved.flatMap { id -> [UUID] in [id] + Self.folders(p.children(of: id), prefix: "").map(\.id) })
        Button("Add to Favorites") { bulkPlace(at: .favorites(.max)) }
            .disabled(!canFavorite)
        Menu(parts.saved.isEmpty ? "Save to Folder" : "Move to Folder") {
            ForEach(Self.folders(p.items, prefix: "").filter { !inside.contains($0.id) }) { f in
                Button(f.label) { bulkPlace(at: .items(parent: f.id, index: .max)) }
            }
            Divider()
            Button("Top Level") { bulkPlace(at: .items(parent: nil, index: .max)) }
        }
        Button("New Folder with Selection") { bulkNewFolder() }
        Divider()
        if !closed.isEmpty {
            Button("Open \(Self.count(closed.count, "Link", "Links"))") { bulkOpen() }
        }
        Button("Copy \(Self.count(parts.tabs.count + parts.links.count, "Link", "Links"))") { bulkCopy() }
            .disabled(parts.tabs.isEmpty && parts.links.isEmpty)
        if !open.isEmpty {
            if s.can(.reload) { Button("Reload \(Self.count(open.count, "Tab", "Tabs"))") { bulkReload() } }
            if s.can(.mute) {
                // Mute while any of them can still be heard.
                let mute = open.contains { !$0.muted }
                let title: String = (mute ? "Mute " : "Unmute ") + Self.count(open.count, "Tab", "Tabs")
                Button(title) { bulkMute(mute) }
            }
        }
        Divider()
        if !open.isEmpty {
            Button("Close \(Self.count(open.count, "Tab", "Tabs"))") { bulkClose() }
        }
        if !parts.saved.isEmpty {
            Button("Remove \(Self.count(parts.saved.count, "Saved Item", "Saved Items"))", role: .destructive) { bulkRemove() }
        }
        Divider()
        Button("Deselect All") { animate { selection.clear() } }
    }

    /// Puts everything picked at `spot`: the Favorites, saved links and
    /// folders move there together, and the tabs are saved after them, each
    /// keeping its tab as a single save does.
    private func bulkPlace(at spot: SidebarProfile.Spot) {
        guard let n = now() else { return }
        let parts = selection.parts(in: n.rows, of: n.profile)
        let saving = parts.tabs.compactMap { n.match.byId[$0] }
        let links = saving.map { Self.saved(sidebar.current($0)) }
        edit(n.profile.id) { $0.place(parts.saved, adding: links, at: spot) }
        for (t, l) in zip(saving, links) { holdIfSaved(t, l) }
        animate { selection.clear() }
    }

    /// Finder's New Folder with Selection: a folder where the first picked
    /// saved thing was, holding everything picked, its name ready to type.
    private func bulkNewFolder() {
        guard let n = now() else { return }
        let parts = selection.parts(in: n.rows, of: n.profile)
        guard !parts.isEmpty else { return }
        let saving = parts.tabs.compactMap { n.match.byId[$0] }
        let links = saving.map { Self.saved(sidebar.current($0)) }
        var made: UUID?
        edit(n.profile.id) { made = $0.addFolder("New Folder", holding: parts.saved, and: links) }
        for (t, l) in zip(saving, links) { holdIfSaved(t, l) }
        animate { selection.clear() }
        if let made { startRename(made, "New Folder") }
    }

    private func bulkOpen() {
        guard let n = now() else { return }
        for l in pickedThings(n).closed { tabs.open(l, in: n.match.session, windowId: n.match.window?.id) }
        animate { selection.clear() }
        sidebar.returnFocusToBrowser()
    }

    /// The addresses, one to a line: the picked tabs', then the saved links'.
    private func bulkCopy() {
        guard let n = now() else { return }
        let parts = selection.parts(in: n.rows, of: n.profile)
        let urls = parts.tabs.compactMap { n.match.byId[$0]?.url } + parts.links.map(\.url)
        if !urls.isEmpty { TabsModel.copy(urls.joined(separator: "\n")) }
    }

    private func bulkReload() {
        guard let n = now() else { return }
        for t in pickedThings(n).open { tabs.reload(t, in: n.match.session) }
    }

    private func bulkMute(_ muted: Bool) {
        guard let n = now() else { return }
        for t in pickedThings(n).open { tabs.setMuted(muted, t, in: n.match.session) }
    }

    /// Closes the tabs behind what is picked. The saved links stay saved.
    private func bulkClose() {
        guard let n = now() else { return }
        tabs.close(pickedThings(n).open, in: n.match.session)
        animate { selection.clear() }
    }

    /// Removes the picked Favorites, saved links and folders, with one Undo
    /// for all of them. Folders with things in them ask first, as one does.
    private func bulkRemove() {
        guard let n = now() else { return }
        let parts = selection.parts(in: n.rows, of: n.profile)
        guard !parts.saved.isEmpty else { return }
        let label = Self.count(parts.saved.count, "item", "items")
        if parts.hasFullFolder {
            confirmDelete = (parts.saved, label)
        } else {
            deleteWithUndo(parts.saved, label, n.profile)
            animate { selection.clear() }
        }
    }

    /// The Delete key with several rows picked: closes the tabs behind them,
    /// as it does for one row; with none of them open, removes the saved ones.
    private func bulkDelete() {
        guard let n = now() else { return }
        if pickedThings(n).open.isEmpty { bulkRemove() } else { bulkClose() }
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
        let keys = SidebarDrag.keys(in: key)
        // Several picked rows dragged as one: when any of them would land.
        if keys.count > 1 {
            if keys.contains(where: { $0.hasPrefix(tabKeyPrefix) }) { return true }
            var after = p
            return !after.place(keys.compactMap(Self.savedID), at: spot).isEmpty
        }
        if let id = Self.savedID(key) { return p.canPlace(id, at: spot) }
        return key.hasPrefix(tabKeyPrefix)
    }

    /// What a drag of `row` carries: every picked row when it is one of
    /// several picked (they move together, as files do in Finder), else itself.
    private func dragKey(_ row: SidebarRowID) -> String {
        guard selection.count > 1, selection.contains(row), let n = now() else { return key(for: row) }
        return SidebarDrag.joined(selection.ordered(in: n.rows).map(key(for:)))
    }

    private func key(for row: SidebarRowID) -> String {
        switch row {
        case .favorite(let id), .folder(let id), .link(let id): return Self.savedKey(id)
        case .tab(let id): return tabKeyPrefix + String(id)
        }
    }

    /// Starts a drag of `key`, remembering it for the drop targets.
    private func drag(_ key: String) -> NSItemProvider {
        let had = newTabHasKeyboard
        let caret = had ? newTabEditor.map { NSMaxRange($0.selectedRange()) } : nil
        DragTrace.log("drag: began \(key.prefix { $0 != ":" }), New Tab had the keyboard \(had), caret \(caret.map(String.init) ?? "none") (\(newTabTrace))")
        dragFocus.began(focused: had, caret: caret)
        animate { dragging = key }
        dragCount += 1
        let mine = dragCount
        // SwiftUI says nothing about a drag dropped elsewhere or cancelled: the
        // mouse button coming up ends it, a moment later so a drop lands first.
        Task { @MainActor in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .milliseconds(300))
            if dragCount == mine, dragging != nil { animate { dragging = nil } }
        }
        return SidebarDrag.provider(for: key)
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

    /// Dropped keys, in order: a tab is saved there, a favorite, saved link
    /// or folder moves there.
    @discardableResult
    private func apply(_ dropped: [String], at spot: SidebarProfile.Spot, _ p: SidebarProfile, _ open: [BrowserTab]) -> Bool {
        let keys = dropped.flatMap(SidebarDrag.keys(in:))
        // Several picked rows dropped as one: the saved ones move there
        // together, and the tabs are saved after them.
        if keys.count > 1 {
            let saving = keys.compactMap { tab(forDragKey: $0, in: open) }
            let links = saving.map { Self.saved(sidebar.current($0)) }
            var placed: [UUID] = []
            edit(p.id) { placed = $0.place(keys.compactMap(Self.savedID), adding: links, at: spot) }
            for (t, l) in zip(saving, links) { holdIfSaved(t, l) }
            if !placed.isEmpty { animate { selection.clear() } }
            return !placed.isEmpty
        }
        var did = false
        var next = spot
        for k in keys {
            var changed = false
            if let t = tab(forDragKey: k, in: open) {
                let at = next, link = Self.saved(sidebar.current(t))
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
        deleteWithUndo([id], label, p)
    }

    /// Several deleted at once come back with one Undo (`label`: how many).
    private func deleteWithUndo(_ ids: [UUID], _ label: String, _ p: SidebarProfile) {
        var removed: [SidebarProfile.Removed] = []
        edit(p.id) { removed = $0.take(ids) }
        guard !removed.isEmpty else { return }
        let now = Date()
        withAnimation(Motion.quick(reduceMotion)) { undo = (p.id, removed, label, now) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            if undo?.at == now { withAnimation(Motion.quick(reduceMotion)) { undo = nil } }
        }
    }

    private func undoBar(_ u: (profile: UUID, removed: [SidebarProfile.Removed], label: String, at: Date)) -> some View {
        HStack(spacing: DS.Space.space2) {
            Text(u.removed.count == 1 ? "\(u.removed[0].item.isFolder ? "Deleted" : "Removed") \u{201C}\(u.label)\u{201D}" : "Removed \(u.label)")
                .lineLimit(1).foregroundStyle(pal.textSecondary)
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
        .padding(.vertical, DS.Space.space2)
        .background(RoundedRectangle(cornerRadius: DS.Radius.radiusMd, style: .continuous).fill(pal.hover))
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
                .focused($newTabFocused)
                // Back from being a drop zone (DropSwap): the keyboard it had
                // before the drag, now that it is there to take it.
                .onAppear {
                    let owed = dragFocus.fieldAppeared()
                    DragTrace.log("new tab: appeared, owed the keyboard \(owed) (\(newTabTrace))")
                    if owed { giveNewTabTheKeyboard("field appeared"); retryNewTabFocus("field appeared") }
                }
                // Down from the field is the way into the rows. The field
                // editor takes the arrows before onKeyPress, so watch for it.
                .onChange(of: newTabFocused) { _, on in
                    DragTrace.log("new tab: focused \(on)")
                    watchDownKey(on)
                    // Back after a drag: its caret too, once the field editor is in.
                    if on, dragFocus.owes { DispatchQueue.main.async { giveNewTabTheKeyboard("focused") } }
                }
                .onDisappear { watchDownKey(false) }
                .onSubmit {
                    guard !newURL.isEmpty else { return }
                    tabs.open(newURL, in: m.session, windowId: m.window?.id)
                    newURL = ""
                    sidebar.returnFocusToBrowser()
                }
        }
        .padding(.horizontal, DS.Space.space2)
        .frame(minHeight: DS.Size.sizeRow)
    }

    /// The New Tab field really has the keyboard: it is being edited in its
    /// panel, and the panel is the key window. (The focus state alone also
    /// holds a focus that was set and did not take.)
    private var newTabHasKeyboard: Bool {
        guard newTabFocused, let panel = sidebar.panel, panel.isKeyWindow else { return false }
        return newTabEditor != nil
    }

    /// The field editor of the field being edited in this panel.
    private var newTabEditor: NSTextView? {
        (sidebar.panel?.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
    }

    /// For trace.log (BETTERLINK_TRACE=1).
    private var newTabTrace: String {
        let panel = sidebar.panel
        return "focused \(newTabFocused), panel key \(panel?.isKeyWindow ?? false), first responder \(panel?.firstResponder.map { String(describing: type(of: $0)) } ?? "none")"
    }

    /// Gives the New Tab field the keyboard it had when a drag began
    /// (DragFocus). `last`: the last try, whatever comes of it.
    private func giveNewTabTheKeyboard(_ when: String, last: Bool = false) {
        guard dragFocus.owes else { return }
        let before = newTabTrace
        var did = "has the keyboard"
        if newTabHasKeyboard, let editor = newTabEditor {
            // The text as it was, so typing goes on (DragFocus.caret). Only
            // here, never when the field is clicked into: nothing is owed then.
            let now = editor.selectedRange(), length = editor.string.utf16.count
            let caret = dragFocus.caret(selected: now.location..<NSMaxRange(now), length: length)
            if let caret {
                editor.setSelectedRange(NSRange(location: caret, length: 0))
                DragTrace.log("new tab: caret put back at \(caret) of \(length)")
            }
            // Selected otherwise: looked at again until the last try.
            if caret != nil || last { dragFocus.settle() }
        } else {
            did = last ? "gave up" : "focus on its way"
            // It had the keyboard, so its panel was the key window: again now
            // (the panel never activates betterlink, so nothing else changes).
            if let panel = sidebar.panel, !panel.isKeyWindow { panel.makeKey(); did = "panel made key" }
            if !newTabFocused {
                newTabFocused = true
                did = "focus set"
            } else if last, !newTabHasKeyboard {
                // Set, and it did not take: SwiftUI moves the focus only on a change.
                newTabFocused = false
                DispatchQueue.main.async { newTabFocused = true }
                did = "focus set again"
            }
            if last { dragFocus.settle() }
        }
        DragTrace.log("new tab: keyboard, \(when): \(did) (\(before))")
    }

    /// Looks again a turn of the run loop later, and once more when the swap
    /// back has settled: SwiftUI takes a focus only once the field is in the
    /// window, which can be after it is first seen.
    private func retryNewTabFocus(_ when: String) {
        DispatchQueue.main.async { giveNewTabTheKeyboard("\(when), next turn") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { giveNewTabTheKeyboard("\(when), settled", last: true) }
    }

    private func watchDownKey(_ on: Bool) {
        if let m = downKeyMonitor { NSEvent.removeMonitor(m); downKeyMonitor = nil }
        guard on else { return }
        downKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            // Only this panel's own field (other windows have theirs), and not
            // while an input method is choosing among candidates.
            guard e.specialKey == .downArrow, let panel = sidebar.panel, e.window === panel,
                  (e.window?.firstResponder as? NSTextView)?.hasMarkedText() == false,
                  e.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift]) else { return e }
            listFocused = true
            return nil
        }
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
        // Another browser profile or browser: the page opens there and the
        // tab closes here once it has. Never out of a private window.
        if TabTransfer.canSend(tab.url), !m.incognito {
            Button("Send to Another Profile…") {
                // After this menu has closed, so the next one can open.
                DispatchQueue.main.async { SendTabMenu.popUp(sidebar.current(tab), from: m.session, incognito: m.incognito) }
            }
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
            if m.session.can(.mute) && (tab.audible || tab.muted) {
                Button(tab.muted ? "Unmute Tab" : "Mute Tab") { tabs.setMuted(!tab.muted, tab, in: m.session) }
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
        let link = Self.saved(sidebar.current(tab))
        edit(p.id) { add(&$0, link) }
        holdIfSaved(tab, link)
    }

    /// After a save: the tab it came from is the new link's tab from now on
    /// (nothing when the save was refused, such as a Favorite already there).
    private func holdIfSaved(_ tab: BrowserTab, _ link: SavedLink) {
        guard lib.library.allLinkIDs.contains(link.id), let s = sidebar.look.match?.session else { return }
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
        // As the profile's windows are now: `m` is as of this window's last change.
        let all = (tabs.sessions.first { $0.id == m.session.id } ?? m.session).store.orderedWindows.flatMap(\.tabs)
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

    /// What a dragged tab is known by. It names the window too: a tab dropped
    /// on another window's sidebar is not that window's, and two browsers
    /// number their tabs alike.
    private var tabKeyPrefix: String { "betterlink-tab:\(sidebar.window.id):" }

    /// A stable row id for a tab, for the drop line.
    static func rowID(_ t: BrowserTab) -> UUID {
        UUID(uuidString: String(format: "7AB00000-0000-0000-0000-%012llX", UInt64(UInt32(truncatingIfNeeded: t.id)))) ?? UUID()
    }

    /// A tab row as a drop target: another tab of this window dropped before or
    /// after it moves there in the browser.
    private func tabDropRow(_ target: BrowserTab, _ m: Match, _ open: [BrowserTab]) -> some ViewModifier {
        let id = Self.rowID(target)
        func dragged() -> BrowserTab? { dragging.flatMap { tab(forDragKey: $0, in: open) } }
        return DropRowModifier(id: id, horizontal: false, canHold: false, color: pal.accent,
                               size: rowSizes[id] ?? .zero, target: $dropTarget,
                               measured: { rowSizes[id] = $0 },
                               allowed: { zone in
                                   // Chrome keeps pinned tabs first: no drop across that line (review F1).
                                   guard m.session.can(.move), let t = dragged(), t.pinned == target.pinned else { return false }
                                   return TabMove.index(moving: t.index, nextTo: target.index, after: zone == .after) != nil
                               }) { keys, zone in
            dragging = nil
            guard let t = keys.lazy.compactMap({ tab(forDragKey: $0, in: open) }).first,
                  let to = TabMove.index(moving: t.index, nextTo: target.index, after: zone == .after) else { return }
            tabs.move(t, to: to, in: m.session, windowId: m.window?.id)
        }
    }

    private func tab(forDragKey k: String, in tabs: [BrowserTab]) -> BrowserTab? {
        guard k.hasPrefix(tabKeyPrefix), let id = Int(k.dropFirst(tabKeyPrefix.count)) else { return nil }
        return tabs.first { $0.id == id }
    }

    /// One line saying why there are no tabs, and a way to the settings.
    @ViewBuilder
    private func emptyState(_ look: SidebarLook) -> some View {
        if let text = emptyText(look) {
            VStack(alignment: .leading, spacing: DS.Space.space3) {
                Text(text)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(pal.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open betterlink") { BetterlinkWindow.open(.sidebar) }
                    .buttonStyle(.dsSecondary)
            }
            .padding(DS.Space.space4)
        }
    }

    private func emptyText(_ look: SidebarLook) -> String? {
        switch look {
        case .window, .connecting: return nil
        case .unseen: return "betterlink can't see this window's tabs."
        case .notConnected: return "Tabs aren't set up for \(sidebar.window.target.appName)."
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

    typealias Match = SidebarLook.Match
}

#if DEBUG
extension SidebarView {
    /// For the layout test: the sidebar as it is while `key` is dragged.
    init(dragging key: String?) {
        self.init()
        _dragging = State(initialValue: key)
    }
}
#endif

private struct SidebarTabRow: View {
    let tab: BrowserTab
    /// What it shows of the tab's title: new titles alone come through it
    /// without the row being made again (`SidebarInstance.show`).
    @ObservedObject var title: TabTitle
    /// Whether the installed extension can mute: the speaker is a button then.
    let canMute: Bool
    let focused: Bool
    /// Picked with other rows for one action on all of them.
    let picked: Bool
    let activate: () -> Void
    let close: () -> Void
    let mute: () -> Void
    @State private var hovering = false

    @Environment(\.sidebarColors) private var pal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let name = title.text
        let shown = name.isEmpty ? tab.url : name
        SidebarRow(selected: tab.active, focused: focused, picked: picked, label: shown, action: activate) {
            SavedIcon(icons: [tab.favIconUrl], title: URL(string: tab.url)?.host() ?? shown)
            Text(shown)
                .font(DS.TextStyle.body)
                .lineLimit(1)
                .foregroundStyle(pal.text)
        } trailing: {
            // The close button comes in to the left of the speaker, so the
            // speaker never moves under the pointer and a click meant to
            // mute can't close the tab.
            if hovering || focused {
                Button(action: close) { RowIcon("xmark") }
                    .buttonStyle(PressStyle())
                    .foregroundStyle(pal.textSecondary)
                    .help("Close tab")
                    .accessibilityLabel("Close \(name)")
                    .transition(.opacity)
            }
            TabSpeaker(tab: tab, name: name, canMute: canMute, mute: mute)
        }
        .animation(Motion.hover(reduceMotion), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityAction(named: Text("Close")) { close() }
    }
}

/// The speaker of a tab that plays sound or is silenced: a button that mutes
/// and unmutes it when the installed extension can, else only a sign. Shown on
/// open tabs, saved links and Favorites alike; nothing while the tab is quiet.
private struct TabSpeaker: View {
    let tab: BrowserTab
    let name: String
    let canMute: Bool
    /// On a Favorite's tile: on a small disc of its own, in the text color,
    /// so it reads on the tile whatever the tile's color.
    var onTile = false
    let mute: () -> Void

    @Environment(\.sidebarColors) private var pal

    var body: some View {
        if tab.audible || tab.muted {
            let speaker = RowIcon(tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .background { if onTile { Circle().fill(.regularMaterial).frame(width: 18, height: 18) } }
            if canMute {
                Button(action: mute) { speaker }
                    .buttonStyle(PressStyle())
                    .foregroundStyle(onTile ? pal.text : pal.textTertiary)
                    .help(tab.muted ? "Unmute tab" : "Mute tab")
                    .accessibilityLabel(tab.muted ? "Unmute \(name)" : "Mute \(name)")
            } else {
                speaker.foregroundStyle(onTile ? pal.text : pal.textTertiary)
                    .accessibilityLabel(tab.muted ? "Muted" : "Playing sound")
            }
        }
    }
}

/// Everything a tab's row shows or its actions use. Another tab's title is not
/// in it: with many busy tabs, only the rows that changed are drawn again.
/// Whatever the row's closures come to read must be added here, or they would
/// act on what it was when the row was last drawn. Its own title is in it too,
/// but new titles alone reach the row through `TabTitle` without a new look,
/// and what a row's actions take of the title is read when they run
/// (`SidebarInstance.current`).
private struct RowKey: Equatable {
    struct Place: Equatable { var id: Int; var pinned: Bool }
    var tab: BrowserTab
    var order: [Place]
    var claimed: Set<Int>
    var session: String
    var ops: Set<String>
    var window: Int?
    var profile: SidebarProfile
    var focused: Bool
    /// What is picked, while this row is: its menu is then the one for all of it.
    var picked: SidebarSelection?
    var drop: DropZone?
    var size: CGSize?
    var palette: SidebarPalette?
    var reduceMotion: Bool
}

/// A tab's title, as `TabTitle` has it now, after `before`; its address
/// while it has none.
private struct TabTitleText: View {
    @ObservedObject var title: TabTitle
    let url: String
    var before = ""
    var body: some View { Text(before + (title.text.isEmpty ? url : title.text)) }
}

/// Draws its content again only when `key` changes.
private struct SkipUnchanged<Key: Equatable, Content: View>: View, Equatable {
    let key: Key
    @ViewBuilder let content: () -> Content
    nonisolated static func == (a: Self, b: Self) -> Bool { a.key == b.key }
    var body: some View { content() }
}

/// A row's small button: a 20 pt target.
private struct RowIcon: View {
    let symbol: String
    init(_ symbol: String) { self.symbol = symbol }
    var body: some View {
        Image(systemName: symbol).font(DS.TextStyle.caption).frame(width: 20, height: 20).contentShape(Rectangle())
    }
}

/// What a folder's row shows before its name: its icon when it has one, in
/// place of the folder glyph, else the glyph (filled while open). A symbol
/// this Mac doesn't draw (synced from a newer macOS) and a kind this
/// betterlink doesn't know show the glyph.
private struct FolderGlyph: View {
    let icon: FolderIcon?
    let expanded: Bool
    @Environment(\.sidebarColors) private var pal

    var body: some View {
        Group {
            switch icon {
            case .emoji(let e)?:
                Text(e).font(DS.TextStyle.body).lineLimit(1).minimumScaleFactor(0.5)
            case .symbol(let name)? where SymbolCheck.exists(name):
                Image(systemName: name).foregroundStyle(pal.textSecondary)
            default:
                Image(systemName: expanded ? "folder.fill" : "folder").foregroundStyle(pal.textSecondary)
            }
        }
        .frame(width: 16)
        .accessibilityHidden(true)
    }
}

/// One row of the sidebar: a button, with its own small buttons after it.
private struct SidebarRow<Content: View, Trailing: View>: View {
    var indent: CGFloat = 0
    var selected = false
    var focused = false
    /// Picked with other rows for one action on all of them (SidebarSelection).
    var picked = false
    /// Its name is being typed: the row is not a button meanwhile.
    var editing = false
    let label: String
    let action: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let trailing: Trailing
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let inside = HStack(spacing: DS.Space.space2) { content }
            .padding(.leading, DS.Space.space2 + indent)
            .frame(maxWidth: .infinity, minHeight: DS.Size.sizeRow, alignment: .leading)
            .contentShape(Rectangle())
        HStack(spacing: 2) {
            if editing {
                inside
            } else {
                Button(action: action) { inside }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label)
                    .accessibilityAddTraits(selected || picked ? .isSelected : [])
            }
            trailing
            // A check, not a color alone: the tab you are on has the same fill.
            if picked { PickedMark().transition(Motion.pop(reduceMotion)) }
        }
        .padding(.trailing, DS.Space.space1)
        .rowStyle(selected: selected || picked, focused: focused)
    }
}

private extension SidebarRow where Trailing == EmptyView {
    init(indent: CGFloat = 0, selected: Bool = false, focused: Bool = false, picked: Bool = false, editing: Bool = false,
         label: String, action: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.init(indent: indent, selected: selected, focused: focused, picked: picked, editing: editing, label: label,
                  action: action, content: content, trailing: { EmptyView() })
    }
}

private struct RowStyle: ViewModifier {
    var selected: Bool
    var focused: Bool
    @Environment(\.sidebarColors) private var pal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: DS.Radius.radiusSm, style: .continuous)
                .fill(selected ? pal.selected : (hovering ? pal.hover : .clear)))
            .modifier(FocusRing(on: focused, radius: DS.Radius.radiusSm))
            .animation(Motion.hover(reduceMotion), value: hovering)
            .animation(Motion.quick(reduceMotion), value: selected)
            .onHover { hovering = $0 }
    }
}

/// On a row or a Favorite picked with others for one action on all of them.
private struct PickedMark: View {
    @Environment(\.sidebarColors) private var pal
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(DS.TextStyle.caption)
            .foregroundStyle(pal.text)
            .frame(width: 20, height: 20)
            .accessibilityHidden(true)
    }
}

/// The keyboard's place, drawn around a row or a Favorite.
private struct FocusRing: ViewModifier {
    var on: Bool
    var radius: CGFloat
    @Environment(\.sidebarColors) private var pal
    func body(content: Content) -> some View {
        content.overlay {
            if on { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(pal.focus, lineWidth: 2) }
        }
    }
}

/// The edge between the sidebar and the browser window: drag it to resize.
private struct ResizeHandle: View {
    let sidebar: SidebarInstance

    var body: some View {
        ResizeHandleView(sidebar: sidebar)
            .frame(width: 8)
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(sidebar.width)) points")
            .accessibilityAdjustableAction { direction in
                sidebar.nudge(by: direction == .increment ? 10 : -10)
            }
    }
}

/// AppKit, not a SwiftUI gesture: the first press on a panel without the
/// keyboard must already drag, and dragging must not take the keyboard.
private struct ResizeHandleView: NSViewRepresentable {
    let sidebar: SidebarInstance
    func makeNSView(context: Context) -> Handle { Handle(sidebar) }
    func updateNSView(_ view: Handle, context: Context) {}

    final class Handle: NSView {
        private let sidebar: SidebarInstance

        init(_ sidebar: SidebarInstance) { self.sidebar = sidebar; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var needsPanelToBecomeKey: Bool { false }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

        override func mouseDown(with event: NSEvent) {
            // Where the press was: it can arrive late, the pointer already moving.
            sidebar.dragEdge(from: window?.convertPoint(toScreen: event.locationInWindow).x ?? NSEvent.mouseLocation.x)
        }
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
    func rowStyle(selected: Bool, focused: Bool) -> some View { modifier(RowStyle(selected: selected, focused: focused)) }
}

/// The sidebar's text and fill colors: the standard design tokens, or, on a
/// profile color, the readable palette made for it (SidebarPalette, WCAG AA).
struct SidebarColors {
    var text, textSecondary, textTertiary, hover, selected, accent, focus: Color
    /// On a profile color, the scheme whose system colors read on it: dark for
    /// light text, light for dark text. Nil keeps the app's own appearance.
    var scheme: ColorScheme?

    init(_ p: SidebarPalette?) {
        guard let p else {
            scheme = nil
            text = DS.Palette.text; textSecondary = DS.Palette.textSecondary; textTertiary = DS.Palette.textTertiary
            hover = DS.Palette.hover; selected = DS.Palette.selected; accent = DS.Palette.accent
            focus = DS.Palette.focusRing
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
        focus = c(p.foreground)
    }
}

/// Sets the color scheme when there is one to set. The same view either way: a
/// branch would rebuild the whole sidebar each time a profile color comes or goes.
private struct SchemeOverride: ViewModifier {
    var scheme: ColorScheme?
    @Environment(\.colorScheme) private var current
    func body(content: Content) -> some View {
        content.environment(\.colorScheme, scheme ?? current)
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
