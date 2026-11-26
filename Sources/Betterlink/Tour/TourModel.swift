import AppKit
import BetterlinkCore
import SwiftUI

/// What this Mac has, for the steps that only apply to some Macs.
enum TourConditions {
    static func met(installed: [Browser]) -> Set<TourCondition> {
        Set(TourCondition.allCases.filter { condition in
            switch condition {
            case .sidebarBrowser: installed.contains { $0.hostsSidebar }
            case .dia: installed.contains { $0.switchesProfileByScript }
            }
        })
    }
}

/// The tour in the window (docs/tour.md): the first run, What's New and the
/// replay, all drawn by TourView from the same steps. BetterlinkCore's Tour
/// decides which steps; this holds the one being shown and remembers what was
/// seen. Nothing here runs while no tour is on screen.
@MainActor
final class TourModel: ObservableObject {
    static let shared = TourModel(defaults: MenuBarIcon.defaults(), installed: { AppModel.installedBrowsers() },
                                  override: ProcessInfo.processInfo.environment["BETTERLINK_TOUR"])

    private let defaults: UserDefaults
    /// The browsers on this Mac, asked each time the window opens.
    private let installed: @MainActor () -> [Browser]
    /// The tour on screen, or nil.
    @Published private(set) var session: TourSession?
    @Published private(set) var seen: TourSeen
    @Published private(set) var met: Set<TourCondition>
    /// The topics opened from the list of further topics, this showing.
    @Published private(set) var opened: Set<String> = []
    /// Whether the last move went forward, so a step comes in from that side.
    private(set) var movedForward = true
    /// BETTERLINK_TOUR, a development aid: off, welcome or new. Used once,
    /// except off, which holds for the whole run.
    private var override: String?

    /// `shared` is the app's; tests make their own on throwaway preferences.
    init(defaults: UserDefaults, installed: @escaping @MainActor () -> [Browser], override: String? = nil) {
        self.defaults = defaults
        self.installed = installed
        self.override = override
        seen = TourSeen(defaults: defaults)
        met = TourConditions.met(installed: installed())
    }

    /// What's New: steps added or changed since the tour was last seen. The
    /// window offers these; they never open over it by themselves.
    var news: [TourPlan.Entry] { Tour.news(seen: seen, met: met) }

    /// The window opened. `offer`: the person opened it themselves (not a
    /// problem to read, not a page that was asked for), so this is the moment
    /// for what `betterlink tour show` asked for while betterlink wasn't
    /// running, or else for the first run, once.
    func windowOpened(offer: Bool) {
        let now = TourConditions.met(installed: installed())
        if now != met { met = now }
        guard offer, session == nil else { return }
        if let request = TourAgent.takeRequest(from: defaults) {
            start(request.mode, topic: request.topic)
            return
        }
        let mode = Tour.modeWhenWindowOpens(seen: seen, override: override)
        if override != "off" { override = nil }
        if let mode { start(mode) }
    }

    /// The window closed with the tour on it: the same as Skip. The tour is
    /// over, so it neither covers the window the next time it opens nor
    /// starts again by itself.
    func windowClosed() { finish() }

    func start(_ mode: TourPlan.Mode, topic: String? = nil) {
        guard let plan = Tour.plan(mode, topic: topic, seen: seen, met: met), let session = TourSession(plan) else { return }
        opened = []
        movedForward = true
        self.session = session
        markSeen()
    }

    func next() {
        guard var s = session else { return }
        movedForward = true
        if s.next() {
            session = s
            markSeen()
        } else {
            finish()
        }
    }

    func back() {
        guard var s = session else { return }
        movedForward = false
        s.back()
        session = s
    }

    /// Opens a topic from the list of further topics.
    func open(topic id: String) {
        guard var s = session else { return }
        movedForward = true
        s.open(topic: id)
        opened.insert(id)
        session = s
        markSeen()
    }

    /// Done or Skip. Either way the tour is over and What's New starts from
    /// today: everything there is now counts as seen. One topic opened by
    /// itself only closes.
    func finish() {
        guard let s = session else { return }
        if s.plan.mode != .topic { catchUp() }
        session = nil
    }

    /// Dismisses What's New without showing it.
    func catchUp() {
        seen.seeAll(in: TourRegistry.topics, met: met)
        seen.save(to: defaults)
    }

    /// A `betterlink` command ran. It may have changed what was seen, or have
    /// asked for the tour just now: then `showWindow` brings the window up
    /// and the tour starts on it. Returns whether it did.
    @discardableResult
    func reload(showWindow: (() -> Void)? = nil) -> Bool {
        let saved = TourSeen(defaults: defaults)
        if saved != seen { seen = saved }
        // Only a request made a moment ago: an older one was made while
        // betterlink wasn't running, and waits for the window to be opened.
        guard let request = TourAgent.takeRequest(from: defaults, within: TourAgent.requestIsNow) else { return false }
        if let showWindow { showWindow() } else { (NSApp.delegate as? AppDelegate)?.showWindow(offerTour: false) }
        start(request.mode, topic: request.topic)
        return session != nil
    }

    /// A step counts as seen once it has been on screen.
    private func markSeen() {
        guard let step = session?.entry?.step, seen.standing(of: step) != .seen else { return }
        seen.see(step)
        seen.save(to: defaults)
    }
}
