import BetterlinkCore
import Foundation
import Testing
@testable import Betterlink

/// When the tour comes up, and when it must not (docs/tour.md, "The rules it
/// follows"). Each test has its own throwaway preferences, so nothing here
/// reads or writes betterlink's.
@MainActor @Suite struct TourModelTests {
    /// A model on empty preferences, as on a Mac that never ran betterlink.
    private func with(installed: [Browser] = [], override: String? = nil,
                      _ body: (TourModel, UserDefaults) throws -> Void) rethrows {
        let name = "betterlink.tests.tour.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(TourModel(defaults: defaults, installed: { installed }, override: override), defaults)
    }

    private func ask(_ defaults: UserDefaults, _ input: [String: Any] = [:], at now: Date = Date()) {
        _ = TourAgent.run("tour.show", input: input, defaults: defaults, met: [], now: now)
    }

    @Test func theFirstRunWaitsForThePersonToOpenTheWindow() {
        with { tour, defaults in
            // The window opened to report a problem, or on a page that was asked for.
            tour.windowOpened(offer: false)
            #expect(tour.session == nil)
            #expect(TourSeen(defaults: defaults) == TourSeen())

            tour.windowOpened(offer: true)
            #expect(tour.session?.plan.mode == .welcome)
        }
    }

    @Test func aStepIsSeenOnceItHasBeenOnScreen() {
        with { tour, defaults in
            tour.windowOpened(offer: true)
            #expect(tour.seen.steps.count == 1)
            tour.next()
            #expect(tour.seen.steps.count == 2)
            tour.back()
            #expect(tour.seen.steps.count == 2)
            // Remembered as it happens, not when the tour ends.
            #expect(TourSeen(defaults: defaults) == tour.seen)
            #expect(!tour.seen.welcomed)
        }
    }

    @Test func closingTheWindowIsSkippingTheTour() {
        with { tour, defaults in
            tour.windowOpened(offer: true)
            tour.windowClosed()
            #expect(tour.session == nil)
            #expect(TourSeen(defaults: defaults).welcomed)
            #expect(tour.news.isEmpty)

            // It neither covers the window the next time nor starts again.
            tour.windowOpened(offer: true)
            #expect(tour.session == nil)
        }
    }

    @Test func closingTheWindowWithNoTourOnItChangesNothing() {
        with(override: "off") { tour, defaults in
            tour.windowOpened(offer: true)
            tour.windowClosed()
            #expect(TourSeen(defaults: defaults) == TourSeen())
        }
    }

    @Test func theFirstRunOpensOnce() {
        with { tour, _ in
            tour.windowOpened(offer: true)
            while tour.session != nil { tour.next() }
            #expect(tour.seen.welcomed)
            tour.windowOpened(offer: true)
            #expect(tour.session == nil)
        }
    }

    @Test func whatsNewIsOfferedAndNeverOpensByItself() {
        with { tour, defaults in
            // Someone who finished the tour before one of its steps existed.
            var seen = TourSeen()
            seen.seeAll(in: TourRegistry.topics, met: [])
            seen.forget(TourRegistry.topics[0].steps[0])
            seen.save(to: defaults)
            tour.reload()

            #expect(tour.news.count == 1)
            tour.windowOpened(offer: true)
            #expect(tour.session == nil)

            tour.start(.whatsNew)
            #expect(tour.session?.plan.mode == .whatsNew)
            tour.finish()
            #expect(tour.news.isEmpty)
        }
    }

    @Test func dismissingWhatsNewCatchesUp() {
        with { tour, defaults in
            var seen = TourSeen(welcomed: true)
            seen.save(to: defaults)
            tour.reload()
            #expect(!tour.news.isEmpty)
            tour.catchUp()
            #expect(tour.news.isEmpty)
            seen = TourSeen(defaults: defaults)
            #expect(seen.welcomed && !seen.steps.isEmpty)
        }
    }

    @Test func aStepForSomethingThisMacLacksIsOfferedWhenItApplies() {
        let name = "betterlink.tests.tour.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        // No Chromium browser and no Dia: their steps are left out, and
        // skipping the tour doesn't count them as seen.
        let bare = TourModel(defaults: defaults, installed: { [] })
        bare.windowOpened(offer: true)
        bare.finish()
        #expect(bare.news.isEmpty)

        // The same Mac after a browser the sidebar works with was installed.
        let later = TourModel(defaults: defaults, installed: { Browser.known })
        #expect(!later.news.isEmpty)
        #expect(later.news.allSatisfy { $0.step.requires != nil })
        later.windowOpened(offer: true)
        #expect(later.session == nil)
    }

    @Test func oneTopicOnlyCloses() {
        with { tour, _ in
            tour.start(.topic, topic: "feedback")
            #expect(tour.session?.plan.mode == .topic)
            tour.finish()
            #expect(tour.session == nil)
            // Looking at one topic is not finishing the tour.
            #expect(!tour.seen.welcomed)
        }
    }

    @Test func whatTheCommandAskedForWaitsForThePerson() {
        with { tour, defaults in
            ask(defaults, ["topic": "feedback"])
            // A window that opened for another reason doesn't show it, or lose it.
            tour.windowOpened(offer: false)
            #expect(tour.session == nil)
            #expect(defaults.string(forKey: TourAgent.requestKey) != nil)

            // It comes before the first run, which is still owed afterwards.
            tour.windowOpened(offer: true)
            #expect(tour.session?.plan.mode == .topic)
            #expect(defaults.string(forKey: TourAgent.requestKey) == nil)
            tour.windowClosed()
            tour.windowOpened(offer: true)
            #expect(tour.session?.plan.mode == .welcome)
        }
    }

    @Test func aRunningAppShowsOnlyWhatWasJustAskedFor() {
        with(override: "off") { tour, defaults in
            var shown = 0
            // Asked two minutes ago, while betterlink wasn't running: another
            // command now must not pop the window up.
            ask(defaults, at: Date().addingTimeInterval(-120))
            #expect(!tour.reload(showWindow: { shown += 1 }))
            #expect(shown == 0 && tour.session == nil)
            // It is still there for the person opening the window.
            tour.windowOpened(offer: true)
            #expect(tour.session?.plan.mode == .replay)
            tour.finish()

            ask(defaults)
            #expect(tour.reload(showWindow: { shown += 1 }))
            #expect(shown == 1 && tour.session?.plan.mode == .replay)
        }
    }

    @Test func aRequestFromLongAgoIsDropped() {
        with(override: "off") { tour, defaults in
            ask(defaults, at: Date().addingTimeInterval(-TourAgent.requestLife - 60))
            tour.windowOpened(offer: true)
            #expect(tour.session == nil)
            #expect(defaults.string(forKey: TourAgent.requestKey) == nil)
        }
    }

    @Test func theOverrideIsForDevelopment() {
        with(override: "off") { tour, _ in
            tour.windowOpened(offer: true)
            tour.windowOpened(offer: true)
            #expect(tour.session == nil)
        }
        with(override: "welcome") { tour, defaults in
            var seen = TourSeen()
            seen.seeAll(in: TourRegistry.topics, met: [])
            seen.save(to: defaults)
            tour.reload()
            tour.windowOpened(offer: true)
            #expect(tour.session?.plan.mode == .welcome)
            // Once: closing it and opening the window again shows nothing.
            tour.windowClosed()
            tour.windowOpened(offer: true)
            #expect(tour.session == nil)
        }
    }

    @Test func aCommandThatChangedWhatWasSeenIsPickedUp() {
        with { tour, defaults in
            _ = TourAgent.run("tour.done", input: [:], defaults: defaults, met: [])
            #expect(!tour.seen.welcomed)
            #expect(!tour.reload(showWindow: {}))
            #expect(tour.seen.welcomed)
            tour.windowOpened(offer: true)
            #expect(tour.session == nil)
        }
    }
}
