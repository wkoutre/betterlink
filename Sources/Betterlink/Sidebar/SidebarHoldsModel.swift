import BetterlinkCore
import Foundation
import TabSyncCore

/// The tabs saved links hold, for every connected browser profile (the logic
/// is HoldLedger in BetterlinkCore). A saved link you open keeps its tab while
/// you move around inside the site, like a pinned tab in Arc and Dia.
///
/// Where held tabs were is kept in UserDefaults (this Mac only, never the
/// synced settings folder), so they return to their links after the browser
/// restarts. Tabs in private windows are never held or remembered.
@MainActor
final class SidebarHoldsModel: ObservableObject {
    static let shared = SidebarHoldsModel()

    @Published private(set) var ledger: HoldLedger
    /// Opens on their way: command id -> the link that asked, and when.
    private var opening: [String: (key: String, link: UUID, at: Date)] = [:]
    /// Socket path -> browser profile key, for events that name only the socket.
    private var keys: [String: String] = [:]
    /// A separate domain while `BETTERLINK_HOME` is set, like the sidebar's other state.
    private let defaults = MenuBarIcon.defaults()
    private static let defaultsKey = "sidebar.heldTabs"

    private init() {
        ledger = HoldLedger(remembered: defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String: [String]]] ?? [:])
    }

    /// The browser profile a session belongs to: the extension's id for it,
    /// which stays the same across restarts, else this connection.
    static func key(_ s: BrowserSession) -> String {
        if let i = s.instance, !i.isEmpty { return i }
        return s.id
    }

    func holds(in s: BrowserSession) -> LinkHolds { ledger.holds(for: Self.key(s)) }

    /// Makes `tab` the link's tab from now on. Never in a private window.
    func hold(_ tab: BrowserTab, for link: UUID, in s: BrowserSession) {
        guard !Self.isPrivate(windowId: tab.windowId, in: s) else { return }
        ledger.hold(tab.id, for: link, in: Self.key(s))
    }

    /// A saved link asked for a new tab with this command; the ack names it.
    func opening(command id: String, for link: UUID, in s: BrowserSession, windowId: Int?) {
        if let windowId, Self.isPrivate(windowId: windowId, in: s) { return }
        opening[id] = (Self.key(s), link, Date())
    }

    /// The browser made the tab a saved link asked for.
    func opened(command id: String, tab: Int) {
        guard let o = opening.removeValue(forKey: id) else { return }
        ledger.hold(tab, for: o.link, in: o.key)
    }

    /// The person closed one tab (the browser said so before the tab list changed).
    func closed(tab: Int, socketPath: String) {
        guard let key = keys[socketPath] else { return }
        if ledger.closed(tab: tab, in: key) { save() }
    }

    /// Called with the browsers' tabs after every change, before they are published.
    func settle(_ sessions: [BrowserSession], links: Set<UUID>) {
        var next = ledger
        var browsers: [HoldLedger.Browser] = []
        keys = [:]
        for s in sessions where s.store.hasSnapshot {
            let key = Self.key(s)
            keys[s.socketPath] = key
            let windows = s.store.orderedWindows
            browsers.append(HoldLedger.Browser(
                key: key, session: s.id,
                tabs: windows.filter { !$0.window.incognito }.flatMap { $0.tabs.map { OpenTab(id: $0.id, url: $0.url) } },
                allTabs: Set(windows.flatMap { $0.tabs.map(\.id) })))
        }
        let memoryChanged = next.settle(browsers, links: links)
        // Publish only a change: this runs on every tab event.
        if next != ledger { ledger = next }
        if memoryChanged { save() }
        if !opening.isEmpty { opening = opening.filter { Date().timeIntervalSince($0.value.at) < 30 } }
    }

    private func save() { defaults.set(ledger.remembered, forKey: Self.defaultsKey) }

    static func isPrivate(windowId: Int, in s: BrowserSession) -> Bool {
        s.store.windows[windowId]?.incognito ?? false
    }
}
