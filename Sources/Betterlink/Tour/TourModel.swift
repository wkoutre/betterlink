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
    static let shared = TourModel()

    private let defaults = MenuBarIcon.defaults()
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
    private var override = ProcessInfo.processInfo.environment["BETTERLINK_TOUR"]

    private init() {
        seen = TourSeen(defaults: MenuBarIcon.defaults())
        met = TourConditions.met(installed: AppModel.installedBrowsers())
    }

    /// What's New: steps added or changed since the tour was last seen. The
    /// window offers these; they never open over it by themselves.
    var news: [TourPlan.Entry] { Tour.news(seen: seen, met: met) }

    /// The window opened. Shows what `betterlink tour show` asked for; else,
    /// when `offer` is set, the first run, once.
    func windowOpened(offer: Bool) {
        let now = TourConditions.met(installed: AppModel.installedBrowsers())
        if now != met { met = now }
        if let request = TourAgent.takeRequest(from: defaults) {
            start(request.mode, topic: request.topic)
            return
        }
        guard offer, session == nil else { return }
        let mode = Tour.modeWhenWindowOpens(seen: seen, override: override)
        if override != "off" { override = nil }
        if let mode { start(mode) }
    }

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
        seen.seeAll(in: TourRegistry.topics)
        seen.save(to: defaults)
    }

    /// `betterlink tour …` changed what was seen, or asked for the tour.
    func reload() {
        let saved = TourSeen(defaults: defaults)
        if saved != seen { seen = saved }
        if defaults.string(forKey: TourAgent.requestKey) != nil {
            (NSApp.delegate as? AppDelegate)?.showWindow(offerTour: false)
        }
    }

    /// A step counts as seen once it has been on screen.
    private func markSeen() {
        guard let step = session?.entry?.step, seen.standing(of: step) != .seen else { return }
        seen.see(step)
        seen.save(to: defaults)
    }
}
