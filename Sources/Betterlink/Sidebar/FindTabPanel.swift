import AppKit
import SwiftUI
import TabSyncCore

/// Find Tab: a small panel in the middle of the screen that finds any open tab
/// in every attached browser and profile as you type, and switches to it.
/// Opened with its shortcut (⌃⌥F unless changed) while an attached browser is
/// in front, or from the sidebar's menu. Like the sidebar it never takes the
/// browser out of the front until a tab is picked.
@MainActor
final class FindTabPanel {
    static let shared = FindTabPanel()

    private var panel: Panel?
    private let state = FindTabState()
    private var keys: Any?

    var isShown: Bool { panel?.isVisible == true }

    func toggle() { isShown ? close() : show() }

    func show() {
        TabsModel.shared.start()
        state.query = ""
        state.selected = 0
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // Made each time it opens and dropped when it closes, so tab changes
        // redraw nothing while it is closed.
        panel.contentView = NSHostingView(rootView: FindTabView(state: state) { [weak self] item in self?.pick(item) })
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Wider and taller with larger text, never past the screen.
            let size = NSSize(width: min(DS.scaled(560), visible.width), height: min(DS.scaled(420), visible.height * 0.8))
            panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - visible.height * 0.18,
                                  width: size.width, height: size.height), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
        watchKeys(true)
    }

    func close() {
        watchKeys(false)
        panel?.orderOut(nil)
        // After whatever closed it (a click on a row) has finished with the view.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel?.contentView = nil
        }
    }

    private func pick(_ item: TabSearch.Item) {
        close()
        let model = TabsModel.shared
        guard let session = model.sessions.first(where: { $0.socketPath == item.socketPath }) else { return }
        model.activate(item.tab, in: session)
        NSRunningApplication(processIdentifier: pid_t(session.browserPid))?.activate()
    }

    private func makePanel() -> Panel {
        let p = Panel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.onResign = { [weak self] in self?.close() }
        return p
    }

    /// The arrows, Return and Escape, before the text field's editor takes them.
    private func watchKeys(_ on: Bool) {
        if let keys { NSEvent.removeMonitor(keys); self.keys = nil }
        guard on else { return }
        keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let panel = self.panel, e.window === panel else { return e }
            switch e.keyCode {
            case 125: self.state.move(1); return nil // ↓
            case 126: self.state.move(-1); return nil // ↑
            case 53: self.close(); return nil // ⎋
            case 36, 76: // ↩, enter
                if let item = self.state.current { self.pick(item) }
                return nil
            default: return e
            }
        }
    }

    /// A borderless panel that can take the keyboard, and says when it lost it.
    final class Panel: NSPanel {
        var onResign: (() -> Void)?
        override var canBecomeKey: Bool { true }
        override func resignKey() {
            super.resignKey()
            onResign?()
        }
    }
}

/// What is typed and which result is chosen.
@MainActor
final class FindTabState: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { selected = 0 } } }
    @Published var selected = 0
    /// The results as last drawn, for the keys.
    var results: [TabSearch.Item] = []

    var current: TabSearch.Item? { results.indices.contains(selected) ? results[selected] : nil }

    func move(_ by: Int) {
        guard !results.isEmpty else { return }
        selected = min(max(selected + by, 0), results.count - 1)
    }
}

private struct FindTabView: View {
    @ObservedObject var state: FindTabState
    @ObservedObject private var tabs = TabsModel.shared
    let pick: (TabSearch.Item) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let results = TabSearch.find(state.query, in: TabSearch.items(tabs.sessions), limit: 30)
        let labels = Dictionary(tabs.sessions.map { ($0.socketPath, tabs.label(of: $0)) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.space2) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Palette.textTertiary)
                TextField("Find a tab in any browser", text: $state.query)
                    .textFieldStyle(.plain)
                    .font(DS.TextStyle.title2)
                    .foregroundStyle(DS.Palette.text)
                    .focused($focused)
                    .onAppear { focused = true }
                    .accessibilityLabel("Find a tab")
            }
            .padding(DS.Space.space4)
            Divider()
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.offset) { i, item in
                            row(item, label: labels[item.socketPath] ?? "", chosen: i == state.selected)
                                .id(i)
                                .onTapGesture { pick(item) }
                        }
                    }
                    .padding(DS.Space.space2)
                }
                .onChange(of: state.selected) { _, i in scroller.scrollTo(i) }
            }
            if results.isEmpty {
                Text(state.query.isEmpty ? "Type part of a tab's title or address." : "No open tab matches.")
                    .font(DS.TextStyle.body)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(DS.Space.space4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .font(DS.TextStyle.body)
        .background(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous).fill(.regularMaterial))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.radiusLg, style: .continuous))
        .onAppear { state.results = results }
        .onChange(of: results.map { [$0.socketPath, String($0.tab.id)] }) { _, _ in
            state.results = results
            if state.selected >= results.count { state.selected = max(0, results.count - 1) }
        }
    }

    private func row(_ item: TabSearch.Item, label: String, chosen: Bool) -> some View {
        HStack(spacing: DS.Space.space3) {
            SavedIcon(icons: [item.tab.favIconUrl], title: URL(string: item.tab.url)?.host() ?? item.tab.title)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.tab.title.isEmpty ? TabSearch.shown(item.tab.url) : item.tab.title)
                    .font(DS.TextStyle.body)
                    .foregroundStyle(DS.Palette.text)
                    .lineLimit(1)
                Text("\(label) · \(URL(string: item.tab.url)?.host() ?? TabSearch.shown(item.tab.url))")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if item.tab.audible || item.tab.muted {
                Image(systemName: item.tab.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
        .padding(.horizontal, DS.Space.space3)
        .frame(minHeight: DS.scaled(40))
        .background(RoundedRectangle(cornerRadius: DS.Radius.radiusSm, style: .continuous)
            .fill(chosen ? DS.Palette.selected : Color.clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }
}
