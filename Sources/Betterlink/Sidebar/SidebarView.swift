import AppKit
import SwiftUI
import TabSyncCore

/// What the sidebar panel shows: the bound window's tabs, live.
struct SidebarView: View {
    @EnvironmentObject var sidebar: SidebarController
    @ObservedObject private var tabs = TabsModel.shared
    @State private var newURL = ""

    var body: some View {
        let match = Self.match(target: sidebar.target, sessions: tabs.sessions)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.space2) {
                Image(systemName: "plus").foregroundStyle(DS.Palette.textTertiary)
                TextField("Open a link or search", text: $newURL)
                    .textFieldStyle(.plain)
                    .font(DS.TextStyle.body)
                    .onSubmit {
                        guard !newURL.isEmpty, let m = match else { return }
                        tabs.open(newURL, in: m.session, windowId: m.window?.id)
                        newURL = ""
                        sidebar.returnFocusToBrowser()
                    }
            }
            .padding(.horizontal, DS.Space.space3)
            .padding(.vertical, DS.Space.space2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Palette.hover.opacity(0.6)))
            .padding(DS.Space.space2)
            // Clear of the browser window's traffic lights when bound on the left.
            .padding(.top, 28)

            if let m = match {
                Text([m.session.browser, m.certain ? tabs.profileName(m.session) : nil].compactMap { $0 }.joined(separator: " · "))
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .lineLimit(1)
                    .padding(.horizontal, DS.Space.space4)
                    .padding(.bottom, DS.Space.space1)
            }
            if let m = match, let w = m.window {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(w.tabs) { tab in
                            SidebarTabRow(tab: tab) {
                                tabs.activate(tab, in: m.session)
                            } close: {
                                tabs.close(tab, in: m.session)
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.space2)
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
