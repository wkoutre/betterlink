import AppKit
import BetterlinkCore
import TabSyncCore

/// What the browser's own tab strip offered on a right-click, for when the
/// sidebar stands in for it. Each one is a command to the Tabs extension, and
/// only does something when the installed extension runs that command
/// (`BrowserSession.can`): an older copy keeps working with what it has.
extension TabsModel {
    func setMuted(_ muted: Bool, _ tab: BrowserTab, in s: BrowserSession) {
        guard s.can(.mute) else { return }
        send(.mute(tab.id, muted), to: s)
    }

    func duplicate(_ tab: BrowserTab, in s: BrowserSession) {
        guard s.can(.duplicate) else { return }
        send(.duplicate(tab.id), to: s)
    }

    func reload(_ tab: BrowserTab, in s: BrowserSession) {
        guard s.can(.reload) else { return }
        send(.reload(tab.id), to: s)
    }

    /// Moves a tab to `index` in its window's tab order (or in `windowId`).
    func move(_ tab: BrowserTab, to index: Int, in s: BrowserSession, windowId: Int? = nil) {
        guard s.can(.move) else { return }
        send(.move(tab.id, to: max(0, index), windowId: windowId), to: s)
    }

    func moveToNewWindow(_ tab: BrowserTab, in s: BrowserSession) {
        guard s.can(.newWindow) else { return }
        send(.newWindow(with: tab.id), to: s)
    }

    /// Sends a tab to `url` and shows it: a held tab back to its saved page.
    func navigate(_ tab: BrowserTab, to url: String, in s: BrowserSession) {
        guard s.can(.navigate) else { return }
        send(.navigate(tab.id, to: url), to: s)
    }

    /// Closes several tabs: in one command when the extension can, else one by one.
    func close(_ list: [BrowserTab], in s: BrowserSession) {
        guard !list.isEmpty else { return }
        if s.can(.closeMany) {
            send(.close(list.map(\.id)), to: s)
        } else {
            for t in list { close(t, in: s) }
        }
    }

    /// Opens a saved link in a new tab. The tab it makes becomes the link's
    /// tab (SidebarHoldsModel) when the extension names it in its answer.
    func open(_ link: SavedLink, in s: BrowserSession, windowId: Int?) {
        let id = send(.open(Self.normalize(link.url), windowId: windowId), to: s)
        SidebarHoldsModel.shared.opening(command: id, for: link.id, in: s, windowId: windowId)
    }

    static func copy(_ url: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
}
