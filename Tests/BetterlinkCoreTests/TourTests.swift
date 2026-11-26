import Foundation
import Testing
@testable import BetterlinkCore

struct TourTests {
    private func fresh() -> UserDefaults {
        let name = "betterlink.tests.tour.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func step(_ id: String, revision: Int = 1, changed: String? = nil, requires: TourCondition? = nil) -> TourStep {
        TourStep(id: id, revision: revision, title: "Title of \(id)", body: "Body.", changed: changed, symbol: "star", requires: requires)
    }

    private func topic(_ id: String, _ tier: TourTopic.Tier, _ steps: [TourStep]) -> TourTopic {
        TourTopic(id: id, title: id.capitalized, summary: "Summary.", symbol: "star", tile: .accent, tier: tier, page: nil, steps: steps)
    }

    /// Two essential steps, then a topic of two and a topic only for Macs with Dia.
    private var sample: [TourTopic] {
        [topic("start", .essential, [step("a"), step("b")]),
         topic("extra", .more, [step("c"), step("d")]),
         topic("dia", .more, [step("e", requires: .dia)])]
    }

    // MARK: Which steps show

    @Test func theFirstRunWalksTheEssentialsThenOffersTheRest() throws {
        let plan = try #require(Tour.plan(.welcome, seen: TourSeen(), met: [], topics: sample))
        #expect(plan.steps.map(\.id) == ["a", "b"])
        #expect(plan.steps.allSatisfy { $0.note == nil })
        // The Dia topic isn't offered on a Mac without Dia.
        #expect(plan.more.map(\.id) == ["extra"])
        let withDia = try #require(Tour.plan(.welcome, seen: TourSeen(), met: [.dia], topics: sample))
        #expect(withDia.more.map(\.id) == ["extra", "dia"])
    }

    @Test func onlyTheFirstRunShowsByItself() {
        #expect(Tour.modeWhenWindowOpens(seen: TourSeen()) == .welcome)
        var seen = TourSeen()
        seen.seeAll(in: sample, met: [.dia])
        #expect(Tour.modeWhenWindowOpens(seen: seen) == nil)
        // Something new is offered in the window, never opened over it.
        seen.forget(sample[0].steps[0])
        #expect(Tour.modeWhenWindowOpens(seen: seen) == nil)
        #expect(Tour.news(seen: seen, met: [], topics: sample).map(\.id) == ["a"])
        // The development aid.
        #expect(Tour.modeWhenWindowOpens(seen: TourSeen(), override: "off") == nil)
        #expect(Tour.modeWhenWindowOpens(seen: seen, override: "welcome") == .welcome)
        #expect(Tour.modeWhenWindowOpens(seen: seen, override: "new") == .whatsNew)
    }

    @Test func whatsNewIsEmptyUntilTheFirstRunIsOver() {
        // Nothing has been seen, but that is the first run's job.
        #expect(Tour.news(seen: TourSeen(), met: [], topics: sample).isEmpty)
        #expect(Tour.plan(.whatsNew, seen: TourSeen(), met: [], topics: sample) == nil)
    }

    @Test func finishingCatchesUpSoOnlyLaterStepsAreNew() throws {
        var seen = TourSeen()
        seen.seeAll(in: sample, met: [.dia])
        #expect(seen.welcomed)
        #expect(Tour.news(seen: seen, met: [.dia], topics: sample).isEmpty)

        // The next release adds a step and changes one.
        let next = [topic("start", .essential, [step("a", revision: 2, changed: "Now also does this."), step("b")]),
                    topic("extra", .more, [step("c"), step("d"), step("f")]),
                    topic("dia", .more, [step("e", requires: .dia)])]
        let plan = try #require(Tour.plan(.whatsNew, seen: seen, met: [], topics: next))
        #expect(plan.steps.map(\.id) == ["a", "f"])
        #expect(plan.steps[0].note == .updated("Now also does this."))
        #expect(plan.steps[1].note == .new)
        #expect(plan.more.isEmpty)

        // Seeing them empties What's New again.
        for entry in plan.steps { seen.see(entry.step) }
        #expect(Tour.plan(.whatsNew, seen: seen, met: [], topics: next) == nil)
    }

    /// Finishing the tour on a Mac without Dia leaves Dia's step unseen: it is
    /// not offered while Dia is missing, and is the day Dia is installed.
    @Test func aStepForSomethingThisMacLacksWaitsUntilItApplies() {
        var seen = TourSeen()
        seen.seeAll(in: sample, met: [])
        #expect(seen.steps["e"] == nil)
        #expect(Tour.news(seen: seen, met: [], topics: sample).isEmpty)
        #expect(Tour.news(seen: seen, met: [.dia], topics: sample).map(\.id) == ["e"])
        seen.seeAll(in: sample, met: [.dia])
        #expect(Tour.news(seen: seen, met: [.dia], topics: sample).isEmpty)
    }

    @Test func seeingAnOlderRevisionNeverLowersWhatWasSeen() {
        var seen = TourSeen(steps: ["a": 3])
        seen.see(step("a", revision: 2))
        #expect(seen.steps["a"] == 3)
        #expect(seen.standing(of: step("a", revision: 3)) == .seen)
        #expect(seen.standing(of: step("a", revision: 4)) == .updated)
        #expect(seen.standing(of: step("z")) == .new)
    }

    @Test func oneTopicShowsOnlyItsStepsThatApply() throws {
        let plan = try #require(Tour.plan(.topic, topic: "extra", seen: TourSeen(), met: [], topics: sample))
        #expect(plan.steps.map(\.id) == ["c", "d"])
        #expect(Tour.plan(.topic, topic: "dia", seen: TourSeen(), met: [], topics: sample) == nil)
        #expect(Tour.plan(.topic, topic: "nope", seen: TourSeen(), met: [], topics: sample) == nil)
    }

    // MARK: Going through a plan

    @Test func forwardThroughTheStepsThenTheListThenATopicAndBack() throws {
        let plan = try #require(Tour.plan(.welcome, seen: TourSeen(), met: [], topics: sample))
        var s = try #require(TourSession(plan))
        #expect(s.entry?.id == "a")
        #expect(!s.canGoBack)
        #expect(!s.isLast)
        #expect(s.progress?.index == 0)
        #expect(s.progress?.count == 2)
        do { let went = s.next(); #expect(went) }
        #expect(s.entry?.id == "b")
        do { let went = s.next(); #expect(went) }
        // The list of further topics: the end, unless one is opened.
        #expect(s.place == .more)
        #expect(s.entry == nil)
        #expect(s.isLast)
        s.open(topic: "extra")
        #expect(s.entry?.id == "c")
        #expect(s.detourTopic?.id == "extra")
        #expect(s.progress?.count == 2)
        do { let went = s.next(); #expect(went) }
        #expect(s.entry?.id == "d")
        s.back()
        #expect(s.entry?.id == "c")
        s.back()
        #expect(s.place == .more)
        s.open(topic: "extra")
        do { let went = s.next(); #expect(went) }
        do { let went = s.next(); #expect(went) }
        // A topic ends back at the list, not at the end of the tour.
        #expect(s.place == .more)
        s.back()
        #expect(s.entry?.id == "b")
        do { let went = s.next(); #expect(went) }
        do { let went = s.next(); #expect(!went) }
    }

    @Test func whatsNewEndsAfterItsLastStep() throws {
        var seen = TourSeen()
        seen.seeAll(in: [sample[0]], met: [])
        let plan = try #require(Tour.plan(.whatsNew, seen: seen, met: [], topics: sample))
        var s = try #require(TourSession(plan))
        #expect(s.entry?.id == "c")
        do { let went = s.next(); #expect(went) }
        #expect(s.isLast)
        do { let went = s.next(); #expect(!went) }
        #expect(s.entry?.id == "d")
    }

    @Test func openingATopicThatIsNotOfferedDoesNothing() throws {
        let plan = try #require(Tour.plan(.welcome, seen: TourSeen(), met: [], topics: sample))
        var s = try #require(TourSession(plan))
        s.open(topic: "extra")  // not at the list yet
        #expect(s.entry?.id == "a")
        _ = s.next(); _ = s.next()
        s.open(topic: "dia")  // not offered on this Mac
        #expect(s.place == .more)
        s.closeDetour()
        #expect(s.place == .more)
    }

    // MARK: Remembering

    @Test func whatWasSeenIsKeptPerMac() {
        let d = fresh()
        #expect(TourSeen(defaults: d) == TourSeen())
        var seen = TourSeen()
        seen.see(step("a", revision: 2))
        seen.welcomed = true
        seen.save(to: d)
        #expect(TourSeen(defaults: d) == TourSeen(steps: ["a": 2], welcomed: true))
        // Anything that isn't a revision is dropped, not trusted.
        d.set(["a": 2, "b": "yes", "c": 0, "d": -1] as [String: Any], forKey: TourSeen.stepsKey)
        #expect(TourSeen(defaults: d).steps == ["a": 2])
    }

    // MARK: betterlink tour

    @Test func statusSaysWhatShowsNextAndEachStepsCommand() throws {
        let d = fresh()
        let topics = [topic("start", .essential, [
            TourStep(id: "a", revision: 1, title: "A", body: "Body.", symbol: "star", control: .makeDefaultBrowser, cli: "betterlink default-browser set"),
            TourStep(id: "e", revision: 1, title: "E", body: "Body.", symbol: "star", requires: .dia, cliWhy: "Only macOS can."),
        ])]
        let status = try TourAgent.run("tour.status", input: [:], defaults: d, met: [], topics: topics).get()
        #expect(status["welcomed"] as? Bool == false)
        #expect(status["showsNext"] as? String == "welcome")
        let steps = try #require(((status["topics"] as? [[String: Any]])?.first?["steps"]) as? [[String: Any]])
        #expect(steps[0]["state"] as? String == "new")
        #expect(steps[0]["command"] as? String == "betterlink default-browser set")
        #expect(steps[0]["applies"] as? Bool == true)
        #expect(steps[1]["noCommand"] as? String == "Only macOS can.")
        #expect(steps[1]["applies"] as? Bool == false)
        // Reading changes nothing.
        #expect(TourSeen(defaults: d) == TourSeen())
    }

    @Test func doneAndResetMarkAllOfItOneTopicOrOneStep() throws {
        let d = fresh()
        var out = try TourAgent.run("tour.done", input: [:], defaults: d, met: [], topics: sample).get()
        #expect(out["welcomed"] as? Bool == true)
        #expect(out["showsNext"] as? String == "nothing")
        // Dia's step doesn't apply here, so it is left for the day it does.
        #expect(TourSeen(defaults: d).steps.count == 4)

        out = try TourAgent.run("tour.reset", input: ["step": "c"], defaults: d, met: [], topics: sample).get()
        #expect(out["new"] as? [String] == ["c"])
        #expect(out["showsNext"] as? String == "new")
        out = try TourAgent.run("tour.reset", input: ["topic": "start"], defaults: d, met: [], topics: sample).get()
        #expect(out["new"] as? [String] == ["a", "b", "c"])
        out = try TourAgent.run("tour.done", input: ["topic": "start"], defaults: d, met: [], topics: sample).get()
        #expect(out["new"] as? [String] == ["c"])
        out = try TourAgent.run("tour.done", input: ["step": "c"], defaults: d, met: [], topics: sample).get()
        #expect(out["new"] as? [String] == [])

        // All of it: the first run comes back.
        out = try TourAgent.run("tour.reset", input: [:], defaults: d, met: [], topics: sample).get()
        #expect(out["showsNext"] as? String == "welcome")
        #expect(TourSeen(defaults: d) == TourSeen())
    }

    @Test func aWrongNameIsRefusedAndChangesNothing() {
        let d = fresh()
        func refusal(_ command: String, _ input: [String: Any]) -> String? {
            if case .failure(let r) = TourAgent.run(command, input: input, defaults: d, met: [], topics: sample) { return r.message }
            return nil
        }
        #expect(refusal("tour.done", ["step": "nope"]) == "No step nope. Steps: a, b, c, d, e.")
        #expect(refusal("tour.reset", ["topic": "nope"]) == "No topic nope. Topics: start, extra, dia.")
        #expect(refusal("tour.done", ["step": "a", "topic": "start"]) == "Give step or topic, not both.")
        #expect(refusal("tour.show", ["topic": "nope"]) == "No topic nope. Topics: start, extra, dia.")
        #expect(refusal("tour.show", ["only": "old"]) != nil)
        #expect(refusal("tour.fly", [:]) == "Unknown command tour.fly.")
        #expect(TourSeen(defaults: d) == TourSeen())
        #expect(d.object(forKey: TourAgent.requestKey) == nil)
    }

    @Test func showLeavesARequestTheAppTakesOnce() throws {
        let d = fresh()
        #expect(TourAgent.takeRequest(from: d) == nil)
        _ = try TourAgent.run("tour.show", input: [:], defaults: d, met: [], topics: sample).get()
        var request = TourAgent.takeRequest(from: d)
        #expect(request?.mode == .replay)
        #expect(request?.topic == nil)
        #expect(TourAgent.takeRequest(from: d) == nil)

        _ = try TourAgent.run("tour.show", input: ["topic": "extra"], defaults: d, met: [], topics: sample).get()
        request = TourAgent.takeRequest(from: d)
        #expect(request?.mode == .topic)
        #expect(request?.topic == "extra")

        // What's New with nothing new asks for nothing, and says why.
        var out = try TourAgent.run("tour.show", input: ["only": "new"], defaults: d, met: [], topics: sample).get()
        #expect(out["shown"] as? Bool == false)
        #expect(TourAgent.takeRequest(from: d) == nil)
        _ = try TourAgent.run("tour.done", input: [:], defaults: d, met: [], topics: sample).get()
        _ = try TourAgent.run("tour.reset", input: ["step": "d"], defaults: d, met: [], topics: sample).get()
        out = try TourAgent.run("tour.show", input: ["only": "new"], defaults: d, met: [], topics: sample).get()
        #expect(out["shown"] as? Bool == true)
        #expect(TourAgent.takeRequest(from: d)?.mode == .whatsNew)

        // Anything else under the key is dropped.
        for junk in ["rm -rf", "welcome", "welcome@soon", "fly@1"] {
            d.set(junk, forKey: TourAgent.requestKey)
            #expect(TourAgent.takeRequest(from: d) == nil)
            #expect(d.object(forKey: TourAgent.requestKey) == nil)
        }
    }

    /// `tour show` while betterlink isn't running waits for the person to open
    /// the window. It must not start on some later, unrelated moment.
    @Test func aRequestWaitsForThePersonThenExpires() throws {
        let d = fresh()
        let asked = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try TourAgent.run("tour.show", input: [:], defaults: d, met: [], topics: sample, now: asked).get()
        // The running app is told at once, so it only acts on a request made just now.
        #expect(TourAgent.takeRequest(from: d, now: asked.addingTimeInterval(120), within: TourAgent.requestIsNow) == nil)
        #expect(d.object(forKey: TourAgent.requestKey) != nil)
        // The person opening the window a few minutes later gets it.
        #expect(TourAgent.takeRequest(from: d, now: asked.addingTimeInterval(300))?.mode == .replay)
        #expect(d.object(forKey: TourAgent.requestKey) == nil)

        _ = try TourAgent.run("tour.show", input: [:], defaults: d, met: [], topics: sample, now: asked).get()
        #expect(TourAgent.takeRequest(from: d, now: asked.addingTimeInterval(5), within: TourAgent.requestIsNow)?.mode == .replay)

        // Past its life it is dropped, whoever looks.
        _ = try TourAgent.run("tour.show", input: [:], defaults: d, met: [], topics: sample, now: asked).get()
        #expect(TourAgent.takeRequest(from: d, now: asked.addingTimeInterval(TourAgent.requestLife + 1)) == nil)
        #expect(d.object(forKey: TourAgent.requestKey) == nil)
    }

    @Test func aTopicWithNothingForThisMacIsNotShown() throws {
        let d = fresh()
        let out = try TourAgent.run("tour.show", input: ["topic": "dia"], defaults: d, met: [], topics: sample).get()
        #expect(out["shown"] as? Bool == false)
        #expect(d.object(forKey: TourAgent.requestKey) == nil)
        let with = try TourAgent.run("tour.show", input: ["topic": "dia"], defaults: d, met: [.dia], topics: sample).get()
        #expect(with["shown"] as? Bool == true)
    }

    // MARK: The real tour

    /// What the generator checks in Tour/tour.json, held here too so a hand
    /// edit of the generated file can't slip past.
    @Test func theRealTourKeepsItsPromises() throws {
        let topics = TourRegistry.topics
        let steps = topics.flatMap(\.steps)
        #expect(Set(steps.map(\.id)).count == steps.count)
        #expect(Set(topics.map(\.id)).count == topics.count)
        for step in steps {
            #expect(step.revision >= 1)
            if step.revision > 1 { #expect(step.changed != nil, "\(step.id) changed without saying how") }
            if step.control != nil { #expect((step.cli != nil) != (step.cliWhy != nil), "\(step.id) names a command or says why not") }
        }
        // The first run: welcome first, short, and something left to explore.
        let plan = try #require(Tour.plan(.welcome, seen: TourSeen(), met: Set(TourCondition.allCases)))
        #expect(plan.steps.first?.id == "welcome")
        #expect(plan.steps.count <= 6)
        #expect(!plan.more.isEmpty)
        // Every name the generated enums hold is used by a step.
        #expect(Set(steps.compactMap(\.control)) == Set(TourControl.allCases))
        #expect(Set(steps.compactMap(\.status)) == Set(TourProbe.allCases))
        #expect(Set(steps.compactMap(\.requires)) == Set(TourCondition.allCases))
        #expect(Set(topics.map(\.tile)) == Set(TourTile.allCases))
    }
}
