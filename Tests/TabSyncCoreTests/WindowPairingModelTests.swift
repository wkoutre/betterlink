import Foundation
import Testing
@testable import TabSyncCore

/// A model of what `WindowPairing` is up against, run over random histories
/// with the truth known: some of a browser's real windows are never listed by
/// Accessibility, some never get an entry from the extension, and every word
/// (a window appearing, its title, its frame, the focus) reaches each side late
/// and on its own, the browser's often in one batch.
///
/// At every look: an entry is beside at most one window, and no pairing has
/// title and frame both against it. Whenever both sides have caught up and a
/// moment has passed: no window holds an entry whose real window is another
/// listed window, and a window that alone matches its own entry has it.
///
/// One case is counted, not failed: a pairing first made while a title or
/// frame of either party was still on its way, between two windows that look
/// alike once everything has arrived. What the window looked like a moment
/// ago matched another window's entry, and nothing seen since tells them
/// apart (docs/tabs.md, Known gaps).
struct WindowPairingModelTests {
    /// SplitMix64: the same sequence for a seed on every machine.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        /// Milliseconds from `a` up to `b`.
        mutating func between(_ a: Int, _ b: Int) -> Int { a + below(b - a + 1) }
        mutating func pick<T>(_ of: [T]) -> T { of[below(of.count)] }
    }

    static let titles = ["New Tab", "New Tab", "Inbox", "Docs"]
    static let lefts: [Double] = [0, 900]
    /// `WindowPairing.moment`, in the model's milliseconds.
    static let moment = Int(WindowPairing.moment * 1000)

    struct Real { var reports: Bool; var title: String; var left: Double; var listed = false }
    struct Seen: Equatable { var title: String; var left: Double }
    enum Side { case ours, theirs }
    enum Kind { case appear, title, frame, focus, close }
    struct Word { var time: Int; var order: Int; var side: Side; var kind: Kind; var window: Int?; var seen: Seen? }

    struct Outcome { var failures: [String] = []; var log: [String] = []; var looks = 0, caughtUp = 0, tolerated = 0 }

    /// One history. Times are milliseconds.
    static func run(seed: UInt64, steps: Int = 40, logging: Bool = false) -> Outcome {
        var random = Random(state: seed), out = Outcome()
        var real: [Int: Real] = [:], nextId = 1
        var ours: [Int: Seen] = [:], theirs: [Int: Seen] = [:]
        var ourFocus: Int?, theirFocus: Int?
        var queue: [Word] = [], order = 0, lastSent: [String: Int] = [:]
        var now = 0
        var pairing = WindowPairing()
        var shown: [Int: Int] = [:], madeBehind: Set<[Int]> = []

        func note(_ line: @autoclosure () -> String) { if logging { out.log.append(String(format: "t=%.2f ", Double(now) / 1000) + line()) } }

        /// A word sets out, to arrive `lag` later: each side's words about one
        /// window in the order they were said, the browser's on a 50 ms beat
        /// so that several arrive together.
        func send(_ side: Side, _ kind: Kind, _ window: Int?, _ seen: Seen? = nil, lag: Int) {
            let key = "\(side) \(kind == .focus ? "focus" : String(window ?? 0))"
            let time = max((now + lag + 49) / 50 * 50, lastSent[key] ?? 0)
            lastSent[key] = time
            order += 1
            queue.append(Word(time: time, order: order, side: side, kind: kind, window: window, seen: seen))
        }

        func newWindow() {
            var r = Real(reports: random.unit() < 0.7, title: random.pick(titles), left: random.pick(lefts))
            let id = nextId
            nextId += 1
            if random.unit() < 0.7 { r.listed = true; send(.ours, .appear, id, Seen(title: r.title, left: r.left), lag: random.between(0, 100)) }
            if r.reports, random.unit() < 0.9 { send(.theirs, .appear, id, Seen(title: r.title, left: r.left), lag: random.between(0, 600)) }
            real[id] = r
            note("new window \(id): reports \(r.reports), '\(r.title)' at \(Int(r.left)), listed \(r.listed)")
        }

        func bounds(_ left: Double) -> WindowBounds { WindowBounds(left: left, top: 31, width: 748, height: 1259) }
        func against(_ w: Seen, _ e: Seen) -> (title: Bool, frame: Bool) { (w.title == e.title, w.left == e.left) }

        @discardableResult
        func look(_ why: String) -> [Int: Int] {
            let windows = ours.keys.sorted().map { id in
                WindowPairing.Window(id: id, pid: 7, app: "Google Chrome", frame: bounds(ours[id]!.left), title: ours[id]!.title + " - Chrome", focused: ourFocus == id)
            }
            var session = BrowserSession(socketPath: "/a")
            session.browserPid = 7
            var snapshot = Inbound(type: "snapshot")
            snapshot.seq = 1
            snapshot.windows = theirs.keys.sorted().map { id in
                SnapshotWindow(id: id, focused: theirFocus == id, tabs: [Tab(id: id * 10, windowId: id, title: theirs[id]!.title, active: true)],
                               left: theirs[id]!.left, top: 31, width: 748, height: 1259)
            }
            session.store.apply(snapshot)
            let found = pairing.update(windows, in: [session], now: Double(now) / 1000)
            var held: [Int: Int] = [:]
            for (w, f) in found { if case .window(let hit) = f { held[w] = hit.windowId } }
            out.looks += 1
            note("look (\(why)): ours \(ours.keys.sorted().map { "\($0) '\(ours[$0]!.title)' \(Int(ours[$0]!.left))\(ourFocus == $0 ? " focused" : "")" }), "
                + "theirs \(theirs.keys.sorted().map { "\($0) '\(theirs[$0]!.title)' \(Int(theirs[$0]!.left))\(theirFocus == $0 ? " focused" : "")" }) "
                + "-> \(held.keys.sorted().map { "\($0):\(held[$0]!)" })")
            // First shown while a title, frame or arrival of either party was still on its way.
            for (w, e) in held where shown[w] != e {
                if queue.contains(where: { $0.kind != .focus && ($0.window == w || $0.window == e) }) { madeBehind.insert([w, e]) } else { madeBehind.remove([w, e]) }
            }
            shown = held
            if Set(held.values).count != held.count { out.failures.append("an entry is beside two windows") }
            for (w, e) in held {
                let a = against(ours[w]!, theirs[e]!)
                if !a.title, !a.frame { out.failures.append("window \(w) has entry \(e) though title and frame both say otherwise") }
            }
            return held
        }

        func caughtUp() {
            out.caughtUp += 1
            let held = look("caught up")
            for (w, e) in held where e != w && ours[e] != nil {
                if madeBehind.contains([w, e]), ours[w] == ours[e] {
                    out.tolerated += 1
                    note("tolerated: window \(w) holds entry \(e), paired while a word was on its way, and looks like window \(e)")
                } else {
                    out.failures.append("window \(w) holds entry \(e), whose own window is listed")
                }
            }
            // Where nothing else looks like it, a window has its own tabs.
            for (w, seen) in ours {
                guard let own = theirs[w], seen == own, held[w] != w else { continue }
                let another = ours.contains { $0.key != w && $0.value == own } || theirs.contains { $0.key != w && $0.value == seen }
                if !another { out.failures.append("window \(w) alone matches its entry and doesn't have it") }
            }
        }

        for _ in 0..<random.between(1, 3) { newWindow() }
        for _ in 0..<steps where out.failures.isEmpty {
            // Something happens.
            let r = random.unit(), ids = real.keys.sorted()
            if r < 0.12, real.count < 5 {
                newWindow()
            } else if r < 0.45, !ids.isEmpty {
                let id = random.pick(ids)
                real[id]!.title = random.pick(titles)
                let seen = Seen(title: real[id]!.title, left: real[id]!.left)
                if real[id]!.listed { send(.ours, .title, id, seen, lag: random.between(0, 50)) }
                // The browser's titles are paced: at once, or up to two seconds on.
                if real[id]!.reports { send(.theirs, .title, id, seen, lag: random.unit() < 0.5 ? random.between(0, 100) : random.between(0, 2200)) }
                note("window \(id) shows '\(seen.title)'")
            } else if r < 0.6, !ids.isEmpty {
                let id = random.pick(ids)
                real[id]!.left = random.pick(lefts)
                let seen = Seen(title: real[id]!.title, left: real[id]!.left)
                if real[id]!.listed { send(.ours, .frame, id, seen, lag: random.between(150, 300)) }
                if real[id]!.reports { send(.theirs, .frame, id, seen, lag: random.between(0, 600)) }
                note("window \(id) moves to \(Int(seen.left))")
            } else if r < 0.85 {
                // The words on the focus are the quick ones: both in well under the moment.
                let to: Int? = ids.isEmpty || random.below(ids.count + 1) == ids.count ? nil : random.pick(ids)
                send(.ours, .focus, to, lag: random.between(0, 50))
                send(.theirs, .focus, to, lag: random.between(0, 200))
                note("focus on \(to.map(String.init) ?? "nothing")")
            } else if r < 0.93, !ids.isEmpty {
                let id = random.pick(ids)
                if !real[id]!.listed {
                    real[id]!.listed = true
                    send(.ours, .appear, id, Seen(title: real[id]!.title, left: real[id]!.left), lag: random.between(0, 100))
                    note("window \(id) is listed (its Space shows)")
                }
            } else if ids.count > 1 {
                let id = random.pick(ids), r = real.removeValue(forKey: id)!
                if r.listed { send(.ours, .close, id, lag: random.between(0, 100)) }
                if r.reports { send(.theirs, .close, id, lag: random.between(0, 300)) }
                note("window \(id) closes")
            }
            // Time passes: often not enough for the words to arrive.
            let until = now + random.pick([20, 100, 400, 1000, 3500])
            var turns = 0
            while turns < 1000 {
                turns += 1
                let next = queue.filter { $0.time <= until }.map(\.time).min()
                // The controller looks again when a word on the focus has held.
                if let at = pairing.settlesAt.map({ Int(($0 * 1000).rounded()) }), at <= until, next == nil || at < next! {
                    now = max(now, at)
                    look("a moment later")
                    continue
                }
                guard let next else { break }
                now = max(now, next)
                for word in queue.filter({ $0.time <= now }).sorted(by: { ($0.time, $0.order) < ($1.time, $1.order) }) {
                    guard let id = word.window else { // the focus on nothing
                        if word.side == .ours { ourFocus = nil } else { theirFocus = nil }
                        continue
                    }
                    switch (word.side, word.kind) {
                    case (.ours, .appear): ours[id] = word.seen
                    case (.ours, .title), (.ours, .frame): if ours[id] != nil { ours[id] = word.seen }
                    case (.ours, .focus): ourFocus = id
                    case (.ours, .close): ours[id] = nil
                    case (.theirs, .appear): theirs[id] = word.seen
                    case (.theirs, .title), (.theirs, .frame): if theirs[id] != nil { theirs[id] = word.seen }
                    case (.theirs, .focus): theirFocus = theirs[id] == nil ? nil : id
                    case (.theirs, .close):
                        theirs[id] = nil
                        if theirFocus == id { theirFocus = nil }
                    }
                }
                queue.removeAll { $0.time <= now }
                look("words")
            }
            let quietSince = now
            now = until
            if queue.isEmpty, until - quietSince >= moment, pairing.settlesAt == nil { caughtUp() }
        }
        return out
    }

    /// The seed of the first history; history `i` runs on `seed + i`. A
    /// thousand histories take under two seconds; for a longer run set
    /// PAIRING_MODEL_HISTORIES (and PAIRING_MODEL_SEED for other histories).
    static let seed = ProcessInfo.processInfo.environment["PAIRING_MODEL_SEED"].flatMap(UInt64.init) ?? 20_261_125
    static let histories = ProcessInfo.processInfo.environment["PAIRING_MODEL_HISTORIES"].flatMap(Int.init) ?? 1000

    @Test func randomHistoriesKeepThePromises() {
        var looks = 0, caughtUp = 0, tolerated = 0
        for i in 0..<Self.histories {
            let out = Self.run(seed: Self.seed + UInt64(i))
            looks += out.looks; caughtUp += out.caughtUp; tolerated += out.tolerated
            // PAIRING_MODEL_PRINT=1 prints the histories with a tolerated case.
            if out.tolerated > 0, ProcessInfo.processInfo.environment["PAIRING_MODEL_PRINT"] != nil {
                print("tolerated in history \(i) (seed \(Self.seed + UInt64(i))):\n" + Self.run(seed: Self.seed + UInt64(i), logging: true).log.joined(separator: "\n"))
            }
            guard !out.failures.isEmpty else { continue }
            let again = Self.run(seed: Self.seed + UInt64(i), logging: true)
            Issue.record("history \(i) (seed \(Self.seed + UInt64(i))): \(again.failures)\n\(again.log.joined(separator: "\n"))")
            return // one failing history is enough to read
        }
        print("WindowPairing model: \(Self.histories) histories from seed \(Self.seed), \(looks) looks, \(caughtUp) checks with both sides caught up, \(tolerated) tolerated")
        // The tolerated case must stay the rarity it is, or the model has gone soft.
        #expect(tolerated <= max(1, Self.histories / 500))
    }
}
