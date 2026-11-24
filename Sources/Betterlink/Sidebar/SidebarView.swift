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
                Text([m.session.browser, tabs.profileName(m.session)].compactMap { $0 }.joined(separator: " · "))
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
    }

    /// The browser session and window behind the bound AX window: the session
    /// whose browser process is the frontmost app, then the window whose active
    /// tab's title the AX window title starts with, else the focused window.
    static func match(target: WindowTracker.Target?, sessions: [BrowserSession]) -> Match? {
        guard let t = target else { return nil }
        // Each browser profile is its own session: the window whose reported
        // frame matches the one in front says which profile it is.
        let mine = sessions.filter { $0.browserPid == Int(t.pid) }
        if let h = NSScreen.screens.first?.frame.height {
            let ax = SidebarGeometry.ax(fromCocoa: t.frame, mainScreenHeight: h)
            let front = WindowBounds(left: ax.minX, top: ax.minY, width: ax.width, height: ax.height)
            if let hit = WindowMatch.best(for: front, in: mine), let s = mine.first(where: { $0.id == hit.session }) {
                return Match(session: s, window: s.store.orderedWindows.first { $0.id == hit.windowId })
            }
        }
        guard let s = sessions.first(where: { $0.browserPid == Int(t.pid) })
            ?? sessions.first(where: { $0.browser == t.appName }) else { return nil }
        let windows = s.store.orderedWindows
        let byTitle = windows.filter { w in
            guard let title = w.tabs.first(where: \.active)?.title, !title.isEmpty else { return false }
            return t.title.hasPrefix(title)
        }
        let w = byTitle.count == 1 ? byTitle[0] : (windows.first { $0.window.focused } ?? windows.first)
        return Match(session: s, window: w)
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
