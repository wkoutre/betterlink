import BetterlinkCore
import Foundation
import TabSyncCore

/// What one window's sidebar shows: that window's tabs, or why there are none.
/// Worked out per window from the tab sync (SidebarController) and handed to
/// the view only when it differs, so a change in another window redraws nothing
/// here.
enum SidebarLook: Equatable {
    case window(Match)
    /// The browser is connected, but this window isn't one the extension
    /// reports (Incognito without permission, a profile without it).
    case unseen
    /// Connected, with the first list of tabs still on its way, or which
    /// window this is being settled (a moment).
    case connecting
    case notConnected

    var match: Match? {
        if case .window(let m) = self { return m }
        return nil
    }

    /// A browser profile, as the sidebar shows it.
    struct Profile: Equatable {
        var ref: ProfileRef
        var name: String
        /// The color the browser paints this profile's window frame, when it has one.
        var color: UInt32?
    }

    struct Match: Equatable {
        /// The browser profile's session, as of when this window last changed:
        /// its other windows' tabs may be older (see `SidebarView.elsewhere`).
        var session: BrowserSession
        var window: TabStore.WindowEntry?
        /// The window's Browser Profile, once known.
        var profile: Profile?
        /// The tabs that profile's saved links hold.
        var holds = LinkHolds()
        /// Which tab each saved link stands for in this window (`resolving`).
        var links = LinkResolution()
        var byId: [Int: BrowserTab] = [:]

        var incognito: Bool { window?.window.incognito ?? false }

        func tab(for link: SavedLink) -> BrowserTab? { links.tab(for: link.id).flatMap { byId[$0] } }

        /// The saved links whose tab is the window's active one: what a closed
        /// folder still shows (`SidebarRows.peek`).
        var activeLinks: Set<UUID> { Set(links.tabs.compactMap { byId[$0.value]?.active == true ? $0.key : nil }) }

        /// This match with its saved links resolved against the window's tabs.
        func resolving(_ p: SidebarProfile?) -> Match {
            var m = self
            let open = window?.tabs ?? []
            m.byId = Dictionary(open.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            if let p {
                m.links = LinkResolution(links: p.allLinks, tabs: open.map { OpenTab(id: $0.id, url: $0.url) }, holds: holds)
            }
            return m
        }

        /// Only what the sidebar shows or acts on. The session's other windows
        /// and timings, and where this window is or whether it has the focus,
        /// redraw nothing.
        static func == (a: Match, b: Match) -> Bool {
            a.session.id == b.session.id && a.session.ops == b.session.ops && a.session.browser == b.session.browser
                && a.session.instance == b.session.instance && a.window?.id == b.window?.id
                && a.window?.window.incognito == b.window?.window.incognito && a.window?.tabs == b.window?.tabs
                && a.profile == b.profile && a.holds == b.holds
        }
    }

    /// `new` is this look with only some tabs' titles changed: the same tabs
    /// in the same order, and everything else the same. A sidebar hands such
    /// a change to the rows' titles alone (`SidebarInstance.show`).
    func differsOnlyInTitles(from new: SidebarLook) -> Bool {
        guard case .window(let old) = self, case .window(var titled) = new,
              let before = old.window?.tabs, var entry = titled.window, entry.tabs.count == before.count else { return false }
        entry.tabs = zip(entry.tabs, before).map { t, was in
            var t = t
            t.title = was.title
            return t
        }
        titled.window = entry
        return titled == old
    }

    /// The look for a window of process `pid` (of the browser named `app`)
    /// that `found` says is this browser window.
    @MainActor
    static func make(_ found: WindowPairing.Found, pid: Int, app: String, sessions: [BrowserSession],
                     profiles: [String: Profile], ledger: HoldLedger) -> SidebarLook {
        let candidates = WindowPairing.candidates(pid: pid, app: app, in: sessions)
        switch found {
        case .window(let hit):
            guard let s = candidates.first(where: { $0.id == hit.session }) else { return .unseen }
            return .window(Match(session: s, window: s.store.entry(hit.windowId), profile: s.instance.flatMap { profiles[$0] },
                                 holds: ledger.holds(for: SidebarHoldsModel.key(s))))
        case .notConnected:
            return .notConnected
        case .waiting:
            return .connecting
        case .unseen:
            return candidates.contains { !$0.store.hasSnapshot } ? .connecting : .unseen
        }
    }
}
