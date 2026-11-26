import Foundation

// betterlink's tour: one list of steps (Tour/tour.json, generated into
// TourRegistry) that the first-run flow, What's New and the replay all draw
// from, so they read and look the same. This file decides which steps a person
// sees and remembers which they have seen; the app draws them (docs/tour.md).

/// One screen of the tour: what a thing is for and, when there is something to
/// allow or switch on, the control to do it with.
public struct TourStep: Identifiable, Equatable, Sendable {
    /// What betterlink remembers a person saw. Never reused for another step.
    public let id: String
    /// Raised when the step changes enough to show it again, with `changed`.
    public let revision: Int
    public let title: String
    public let body: String
    /// What is different since the revision before, for people who saw that one.
    public let changed: String?
    public let symbol: String
    /// What the step shows as done or not yet.
    public let status: TourProbe?
    /// What the person can do on the step.
    public let control: TourControl?
    /// What this Mac needs for the step to apply.
    public let requires: TourCondition?
    /// The betterlink command that does the same as the control.
    public let cli: String?
    /// Why no command does, when none does.
    public let cliWhy: String?

    public init(id: String, revision: Int, title: String, body: String, changed: String? = nil, symbol: String,
                status: TourProbe? = nil, control: TourControl? = nil, requires: TourCondition? = nil,
                cli: String? = nil, cliWhy: String? = nil) {
        self.id = id; self.revision = revision; self.title = title; self.body = body; self.changed = changed
        self.symbol = symbol; self.status = status; self.control = control; self.requires = requires
        self.cli = cli; self.cliWhy = cliWhy
    }
}

/// A feature, and the steps that introduce it.
public struct TourTopic: Identifiable, Equatable, Sendable {
    public enum Tier: String, Sendable {
        /// Shown one after another on the first run: what routing links needs.
        case essential
        /// Offered at the end of the first run, to open or leave.
        case more
    }
    public let id: String
    public let title: String
    public let summary: String
    public let symbol: String
    public let tile: TourTile
    public let tier: Tier
    /// The window's page where the feature lives (RootView.Page's saved name).
    public let page: String?
    public let steps: [TourStep]

    public init(id: String, title: String, summary: String, symbol: String, tile: TourTile, tier: Tier, page: String?, steps: [TourStep]) {
        self.id = id; self.title = title; self.summary = summary; self.symbol = symbol
        self.tile = tile; self.tier = tier; self.page = page; self.steps = steps
    }
}

/// Which steps this person has seen, and at which revision. Kept per Mac in
/// UserDefaults, like the other things that belong to one Mac: a settings
/// folder shared between Macs shouldn't mark the tour seen on all of them.
public struct TourSeen: Equatable, Sendable {
    public static let stepsKey = "tour.seen"
    public static let welcomedKey = "tour.welcomed"

    /// Step id to the revision seen.
    public var steps: [String: Int]
    /// The first-run flow was finished or skipped.
    public var welcomed: Bool

    public init(steps: [String: Int] = [:], welcomed: Bool = false) {
        self.steps = steps
        self.welcomed = welcomed
    }

    public init(defaults: UserDefaults) {
        var steps: [String: Int] = [:]
        for (id, revision) in defaults.dictionary(forKey: Self.stepsKey) ?? [:] {
            if let n = revision as? Int, n > 0 { steps[id] = n }
        }
        self.init(steps: steps, welcomed: defaults.bool(forKey: Self.welcomedKey))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(steps, forKey: Self.stepsKey)
        defaults.set(welcomed, forKey: Self.welcomedKey)
    }

    public enum Standing: String, Sendable {
        /// Never shown.
        case new
        /// Shown, before the step changed.
        case updated
        case seen
    }

    public func standing(of step: TourStep) -> Standing {
        guard let revision = steps[step.id] else { return .new }
        return revision < step.revision ? .updated : .seen
    }

    public mutating func see(_ step: TourStep) {
        steps[step.id] = max(steps[step.id] ?? 0, step.revision)
    }

    /// Catches up with everything this Mac was offered: finishing or skipping
    /// the tour means the next What's New holds only what is added after
    /// today. A step for something this Mac lacks (`met`) stays unseen, so it
    /// is offered the day the Mac gets a browser it needs.
    public mutating func seeAll(in topics: [TourTopic], met: Set<TourCondition>) {
        for topic in topics { for step in Tour.applying(topic, met) { see(step) } }
        welcomed = true
    }

    public mutating func forget(_ step: TourStep) {
        steps[step.id] = nil
    }
}

/// The steps one showing of the tour goes through.
public struct TourPlan: Equatable, Sendable {
    public enum Mode: String, Sendable {
        /// The first run: the essential steps, then the rest to choose from.
        case welcome
        /// After an update: only the steps that are new or changed.
        case whatsNew = "new"
        /// The first run again, opened by hand.
        case replay
        /// One topic's steps.
        case topic
    }

    /// Why a step is in What's New.
    public enum Note: Equatable, Sendable {
        case new
        /// The step was seen before it changed; the text says what changed.
        case updated(String?)
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let topic: TourTopic
        public let step: TourStep
        public let note: Note?
        public var id: String { step.id }

        public init(topic: TourTopic, step: TourStep, note: Note? = nil) {
            self.topic = topic; self.step = step; self.note = note
        }
    }

    public let mode: Mode
    /// Shown one after another.
    public let steps: [Entry]
    /// Offered after them, each to open or leave (only steps that apply to this Mac).
    public let more: [TourTopic]

    public init(mode: Mode, steps: [Entry], more: [TourTopic] = []) {
        self.mode = mode; self.steps = steps; self.more = more
    }

    public var isEmpty: Bool { steps.isEmpty && more.isEmpty }
}

public enum Tour {
    /// The steps of a topic that apply to this Mac.
    static func applying(_ topic: TourTopic, _ met: Set<TourCondition>) -> [TourStep] {
        topic.steps.filter { $0.requires.map(met.contains) ?? true }
    }

    /// What's New: the steps never seen, or seen before they changed, in the
    /// tour's order. Empty until the first run is over (that shows everything).
    public static func news(seen: TourSeen, met: Set<TourCondition>, topics: [TourTopic] = TourRegistry.topics) -> [TourPlan.Entry] {
        guard seen.welcomed else { return [] }
        var out: [TourPlan.Entry] = []
        for topic in topics {
            for step in applying(topic, met) {
                switch seen.standing(of: step) {
                case .new: out.append(.init(topic: topic, step: step, note: .new))
                case .updated: out.append(.init(topic: topic, step: step, note: .updated(step.changed)))
                case .seen: break
                }
            }
        }
        return out
    }

    /// The plan for one showing, or nil when there is nothing to show (no such
    /// topic, or nothing new).
    public static func plan(_ mode: TourPlan.Mode, topic: String? = nil, seen: TourSeen, met: Set<TourCondition>,
                            topics: [TourTopic] = TourRegistry.topics) -> TourPlan? {
        let plan: TourPlan
        switch mode {
        case .welcome, .replay:
            var steps: [TourPlan.Entry] = []
            var more: [TourTopic] = []
            for t in topics {
                let applying = applying(t, met)
                if applying.isEmpty { continue }
                switch t.tier {
                case .essential: steps += applying.map { .init(topic: t, step: $0) }
                case .more: more.append(TourTopic(id: t.id, title: t.title, summary: t.summary, symbol: t.symbol, tile: t.tile,
                                                  tier: t.tier, page: t.page, steps: applying))
                }
            }
            plan = TourPlan(mode: mode, steps: steps, more: more)
        case .whatsNew:
            plan = TourPlan(mode: mode, steps: news(seen: seen, met: met, topics: topics))
        case .topic:
            guard let t = topics.first(where: { $0.id == topic }) else { return nil }
            plan = TourPlan(mode: mode, steps: applying(t, met).map { .init(topic: t, step: $0) })
        }
        return plan.isEmpty ? nil : plan
    }

    /// What to show by itself when the window opens: the first run, once.
    /// What's New is never shown unasked; the window offers it (docs/tour.md).
    /// `override` is BETTERLINK_TOUR, a development aid: off, welcome or new
    /// (new shows What's New when there is any; a Mac that never finished the
    /// first run has none).
    public static func modeWhenWindowOpens(seen: TourSeen, override: String? = nil) -> TourPlan.Mode? {
        switch override {
        case "off": return nil
        case "welcome": return .welcome
        case "new": return .whatsNew
        default: return seen.welcomed ? nil : .welcome
        }
    }
}

/// Where a person is in a plan. Pure, so going forward and back is tested
/// without a window.
public struct TourSession: Equatable, Sendable {
    public enum Place: Equatable, Sendable {
        /// A step of the plan.
        case step(Int)
        /// The list of further topics.
        case more
        /// A step of one of those topics, opened from the list.
        case detour(topic: Int, step: Int)
    }

    public let plan: TourPlan
    public private(set) var place: Place

    public init?(_ plan: TourPlan) {
        guard !plan.isEmpty else { return nil }
        self.plan = plan
        place = plan.steps.isEmpty ? .more : .step(0)
    }

    /// The step on screen, or nil on the list of further topics.
    public var entry: TourPlan.Entry? {
        switch place {
        case .step(let i): return plan.steps[i]
        case .more: return nil
        case .detour(let t, let s): return .init(topic: plan.more[t], step: plan.more[t].steps[s])
        }
    }

    /// The topic whose steps are open from the list.
    public var detourTopic: TourTopic? {
        if case .detour(let t, _) = place { return plan.more[t] }
        return nil
    }

    /// Position among the steps being walked, for "2 of 5". Nil on the list.
    public var progress: (index: Int, count: Int)? {
        switch place {
        case .step(let i): return (i, plan.steps.count)
        case .more: return nil
        case .detour(let t, let s): return (s, plan.more[t].steps.count)
        }
    }

    public var canGoBack: Bool {
        switch place {
        case .step(let i): return i > 0
        case .more: return !plan.steps.isEmpty
        case .detour: return true
        }
    }

    /// Going on from here ends the tour.
    public var isLast: Bool {
        switch place {
        case .step(let i): return i == plan.steps.count - 1 && plan.more.isEmpty
        case .more: return true
        case .detour: return false
        }
    }

    /// Goes on. False when that was the end.
    public mutating func next() -> Bool {
        switch place {
        case .step(let i):
            if i + 1 < plan.steps.count { place = .step(i + 1) }
            else if !plan.more.isEmpty { place = .more }
            else { return false }
        case .more:
            return false
        case .detour(let t, let s):
            place = s + 1 < plan.more[t].steps.count ? .detour(topic: t, step: s + 1) : .more
        }
        return true
    }

    public mutating func back() {
        switch place {
        case .step(let i): if i > 0 { place = .step(i - 1) }
        case .more: if !plan.steps.isEmpty { place = .step(plan.steps.count - 1) }
        case .detour(let t, let s): place = s > 0 ? .detour(topic: t, step: s - 1) : .more
        }
    }

    /// Opens a topic from the list.
    public mutating func open(topic id: String) {
        guard case .more = place, let t = plan.more.firstIndex(where: { $0.id == id }) else { return }
        place = .detour(topic: t, step: 0)
    }

    /// Back to the list, from anywhere in a topic opened from it.
    public mutating func closeDetour() {
        if case .detour = place { place = .more }
    }
}

/// The tour's commands for the betterlink CLI (`betterlink tour …`), so an
/// agent can read what a person has seen, show the tour, or put it back.
public enum TourAgent {
    public static let commands = ["tour.status", "tour.show", "tour.done", "tour.reset"]
    /// What the CLI asked the app to show, and when: "welcome", "new" or
    /// "topic:<id>", then "@" and the time in seconds.
    public static let requestKey = "tour.request"
    /// How long a request waits for the window to be opened. Older than this
    /// and it is dropped: nobody expects a tour they asked for yesterday.
    public static let requestLife: TimeInterval = 600
    /// How old a request can be for the running app to open its window for
    /// it. The app is told at once, so anything older was asked while it
    /// wasn't running, and waits for the person to open the window.
    public static let requestIsNow: TimeInterval = 30

    public struct Refusal: Error, Equatable {
        public let message: String
    }

    /// What the CLI asked to be shown, read once. A request older than
    /// `within` is left for later (the person opening the window); one past
    /// `requestLife`, or anything else under the key, is dropped.
    public static func takeRequest(from defaults: UserDefaults, now: Date = Date(),
                                   within: TimeInterval = requestLife) -> (mode: TourPlan.Mode, topic: String?)? {
        guard let raw = defaults.string(forKey: requestKey) else {
            defaults.removeObject(forKey: requestKey)
            return nil
        }
        let parts = raw.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let what = String(parts[0])
        let request: (mode: TourPlan.Mode, topic: String?)? =
            what.hasPrefix("topic:") ? (.topic, String(what.dropFirst("topic:".count)))
            : what == "new" ? (.whatsNew, nil)
            : what == "welcome" ? (.replay, nil) : nil
        guard let request, parts.count == 2, let at = TimeInterval(parts[1]) else {
            defaults.removeObject(forKey: requestKey)
            return nil
        }
        let age = now.timeIntervalSince1970 - at
        // A little slack for a clock that was set back.
        guard age <= requestLife, age >= -60 else {
            defaults.removeObject(forKey: requestKey)
            return nil
        }
        guard age <= within else { return nil }
        defaults.removeObject(forKey: requestKey)
        return request
    }

    public static func run(_ command: String, input: [String: Any], defaults: UserDefaults, met: Set<TourCondition>,
                           topics: [TourTopic] = TourRegistry.topics, now: Date = Date()) -> Result<[String: Any], Refusal> {
        var seen = TourSeen(defaults: defaults)
        func refuse(_ message: String) -> Result<[String: Any], Refusal> { .failure(Refusal(message: message)) }
        let stepIds = topics.flatMap(\.steps).map(\.id).joined(separator: ", ")
        let topicIds = topics.map(\.id).joined(separator: ", ")

        /// The steps `step` or `topic` in the input names; nil when it names neither.
        func named() -> Result<[TourStep]?, Refusal> {
            let step = input["step"] as? String, topic = input["topic"] as? String
            if step != nil && topic != nil { return .failure(Refusal(message: "Give step or topic, not both.")) }
            if let step {
                guard let s = topics.flatMap(\.steps).first(where: { $0.id == step }) else {
                    return .failure(Refusal(message: "No step \(step). Steps: \(stepIds)."))
                }
                return .success([s])
            }
            if let topic {
                guard let t = topics.first(where: { $0.id == topic }) else {
                    return .failure(Refusal(message: "No topic \(topic). Topics: \(topicIds)."))
                }
                return .success(t.steps)
            }
            return .success(nil)
        }

        switch command {
        case "tour.status":
            return .success(report(seen: seen, met: met, topics: topics))
        case "tour.show":
            let request: String
            if let topic = input["topic"] as? String {
                guard topics.contains(where: { $0.id == topic }) else { return refuse("No topic \(topic). Topics: \(topicIds).") }
                // A topic for something this Mac lacks has nothing to show.
                guard Tour.plan(.topic, topic: topic, seen: seen, met: met, topics: topics) != nil else {
                    return .success(["shown": false, "note": "Nothing in \(topic) applies to this Mac (tour status says which steps do)."])
                }
                request = "topic:\(topic)"
            } else if (input["only"] as? String) == "new" {
                if news(seen: seen, met: met, topics: topics).isEmpty {
                    return .success(["shown": false, "note": seen.welcomed ? "Nothing is new since the tour was last seen."
                                                                         : "The first run hasn't happened yet; show the whole tour instead."])
                }
                request = "new"
            } else if input["only"] != nil {
                return refuse("Give only: new, or leave it out for the whole tour.")
            } else {
                request = "welcome"
            }
            defaults.set("\(request)@\(Int(now.timeIntervalSince1970))", forKey: requestKey)
            return .success(["shown": true, "note": "betterlink opens its window on the tour if it is running. If it isn't, open betterlink within ten minutes and the tour starts there."])
        case "tour.done":
            switch named() {
            case .failure(let r): return .failure(r)
            case .success(let steps?): steps.forEach { seen.see($0) }
            case .success(nil): seen.seeAll(in: topics, met: met)
            }
        case "tour.reset":
            switch named() {
            case .failure(let r): return .failure(r)
            case .success(let steps?): steps.forEach { seen.forget($0) }
            case .success(nil): seen = TourSeen()
            }
        default:
            return refuse("Unknown command \(command).")
        }
        seen.save(to: defaults)
        return .success(report(seen: seen, met: met, topics: topics))
    }

    private static func news(seen: TourSeen, met: Set<TourCondition>, topics: [TourTopic]) -> [TourPlan.Entry] {
        Tour.news(seen: seen, met: met, topics: topics)
    }

    /// Everything about the tour on this Mac, for `betterlink tour status`.
    public static func report(seen: TourSeen, met: Set<TourCondition>, topics: [TourTopic] = TourRegistry.topics) -> [String: Any] {
        let new = Tour.news(seen: seen, met: met, topics: topics)
        return [
            "welcomed": seen.welcomed,
            "showsNext": !seen.welcomed ? "welcome" : new.isEmpty ? "nothing" : "new",
            "new": new.map(\.step.id),
            "topics": topics.map { topic -> [String: Any] in
                [
                    "id": topic.id, "title": topic.title, "tier": topic.tier.rawValue,
                    "steps": topic.steps.map { step -> [String: Any] in
                        var out: [String: Any] = [
                            "id": step.id, "title": step.title, "revision": step.revision,
                            "state": seen.standing(of: step).rawValue,
                            "applies": step.requires.map(met.contains) ?? true,
                        ]
                        if let cli = step.cli { out["command"] = cli }
                        if let why = step.cliWhy { out["noCommand"] = why }
                        return out
                    },
                ]
            },
        ]
    }
}
