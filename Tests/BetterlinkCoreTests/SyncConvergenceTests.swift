import Foundation
import Testing
@testable import BetterlinkCore

/// Random edits on simulated Macs that sync partially, in any order, with
/// skewed clocks, must end identical once everyone has read everyone's file
/// (docs/sync.md, Tests).
struct SyncConvergenceTests {
    struct RNG { var s: UInt64
        mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        mutating func pick<T>(_ a: [T]) -> T? { a.isEmpty ? nil : a[int(a.count)] }
    }

    static let shared = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

    struct Mac {
        var clock: HLCClock
        var state = SyncState()
        var rules = RuleStore.Contents()
        var library = SidebarLibrary(profiles: [SidebarProfile(id: SyncConvergenceTests.shared, name: "Shared")])
        var skew: Int64
        let selection = SyncSelection(global: true, profiles: [SyncConvergenceTests.shared: .init()])

        mutating func record(now: Int64) {
            let local = SyncModel.project(rules: rules, library: library, selection: selection,
                                          identity: { ProfileIdentity(name: $0.directory, account: nil) }, state: state)
            state.record(local, scope: SyncModel.scope(selection, state: state), clock: &clock, now: now + skew)
        }

        mutating func read(_ files: [SyncState], now: Int64) {
            for f in files { state = state.merged(with: f) }
            if let m = state.maxStamp { clock.observe(m) }
            let r = SyncModel.materialize(state, rules: rules, library: library, selection: selection, resolve: { _, d, _ in d })
            rules = r.rules; library = r.library
            record(now: now) // what materialize left is this Mac's view now
        }

        var profile: SidebarProfile { library.profiles.first { $0.id == SyncConvergenceTests.shared }! }
        mutating func edit(_ f: (inout SidebarProfile) -> Void) {
            let i = library.profiles.firstIndex { $0.id == SyncConvergenceTests.shared }!
            f(&library.profiles[i])
        }

        /// What must agree across Macs (folder open/closed is per Mac).
        var comparable: String {
            func strip(_ items: [SidebarItem]) -> [SidebarItem] {
                items.map { if case .folder(var f) = $0 { f.expanded = true; f.items = strip(f.items); return .folder(f) }; return $0 }
            }
            var p = profile; p.items = strip(p.items); p.browserProfiles = []
            let e = JSONEncoder(); e.outputFormatting = .sortedKeys
            return String(decoding: try! e.encode(rules), as: UTF8.self) + String(decoding: try! e.encode(p), as: UTF8.self)
        }
    }

    func randomEdit(_ m: inout Mac, _ g: inout RNG) {
        switch g.int(12) {
        case 0, 1: m.rules.rules.append(Rule(kind: .domain, pattern: "site\(g.int(1000)).com", browser: "b", profile: "Default"))
        case 2: if !m.rules.rules.isEmpty { m.rules.rules.remove(at: g.int(m.rules.rules.count)) }
        case 3: if !m.rules.rules.isEmpty { let i = g.int(m.rules.rules.count); m.rules.rules[i].pattern = "edit\(g.int(1000))" }
        case 4: if m.rules.rules.count > 1 { let r = m.rules.rules.remove(at: g.int(m.rules.rules.count)); m.rules.rules.insert(r, at: g.int(m.rules.rules.count + 1)) }
        case 5: m.edit { $0.addFavorite(SavedLink(title: "f", url: "https://fav\(g.int(50)).example")) }
        case 6:
            let folders = SidebarProfile.allFolders(in: m.profile.items).map(\.id)
            let parent: UUID? = g.int(2) == 0 ? nil : g.pick(folders)
            m.edit { $0.addFolder("F\(g.int(100))", in: parent) }
        case 7:
            let folders = SidebarProfile.allFolders(in: m.profile.items).map(\.id)
            let parent: UUID? = g.int(3) == 0 ? nil : g.pick(folders)
            m.edit { $0.addLink(SavedLink(title: "l", url: "https://link\(g.int(100)).example"), in: parent) }
        case 8, 9:
            // Move anything anywhere (place refuses what it must).
            let all = m.profile.favorites.map(\.id) + SidebarProfile.links(in: m.profile.items).map(\.id)
                + SidebarProfile.allFolders(in: m.profile.items).map(\.id)
            guard let id = g.pick(all) else { return }
            let folders = SidebarProfile.allFolders(in: m.profile.items).map(\.id)
            let spot: SidebarProfile.Spot = g.int(4) == 0 ? .favorites(g.int(4)) : .items(parent: g.int(2) == 0 ? nil : g.pick(folders), index: g.int(4))
            m.edit { $0.place(id, at: spot) }
        case 10:
            let all = SidebarProfile.allFolders(in: m.profile.items).map(\.id) + SidebarProfile.links(in: m.profile.items).map(\.id)
            if let id = g.pick(all) { m.edit { $0.rename(id, to: "R\(g.int(100))") } }
        default:
            let all = m.profile.favorites.map(\.id) + SidebarProfile.links(in: m.profile.items).map(\.id)
                + SidebarProfile.allFolders(in: m.profile.items).map(\.id)
            if let id = g.pick(all) { m.edit { $0.remove(id) } }
        }
    }

    @Test(arguments: Array(1...60))
    func randomEditsOnThreeMacsConverge(seed: Int) {
        var g = RNG(s: UInt64(seed) &* 7919)
        var macs = (0..<3).map { Mac(clock: HLCClock(device: "mac\($0)"), skew: Int64($0 == 1 ? -5_000 : $0 == 2 ? 3_000 : 0)) }
        var files: [SyncState?] = [nil, nil, nil]
        var now: Int64 = 1_000_000
        for _ in 0..<150 {
            now += Int64(g.int(40))
            let i = g.int(3)
            switch g.int(5) {
            case 0, 1, 2: randomEdit(&macs[i], &g)
            case 3: macs[i].record(now: now); files[i] = macs[i].state
            default:
                // Read some other Macs' files, in a random order.
                let others = (0..<3).filter { $0 != i && files[$0] != nil }.shuffled(using: &g)
                macs[i].read(others.prefix(g.int(3)).compactMap { files[$0] }, now: now)
            }
        }
        // Everyone writes, then everyone reads everyone, twice.
        for _ in 0..<2 {
            for i in 0..<3 { now += 1; macs[i].record(now: now); files[i] = macs[i].state }
            for i in 0..<3 { now += 1; macs[i].read(files.compactMap { $0 }, now: now); files[i] = macs[i].state }
        }
        // The run produced real content to agree on, deletes included.
        #expect(macs[0].state.entities.count > 5, "only \(macs[0].state.entities.count) entities, seed \(seed)")
        #expect(macs[0].state.entities.keys.contains { $0.hasPrefix("node:") }, "no sidebar nodes, seed \(seed)")
        #expect(macs[0].state == macs[1].state && macs[1].state == macs[2].state, "states differ, seed \(seed)")
        #expect(macs[0].comparable == macs[1].comparable && macs[1].comparable == macs[2].comparable, "settings differ, seed \(seed)")
    }

    @Test func mergeIsCommutativeAssociativeAndIdempotent() {
        func st(_ id: String, _ v: String, _ w: Int64, _ d: String) -> SyncState {
            SyncState(entities: [id: ["x": Stamped(.string(v), HLC(wall: w, counter: 0, device: d))]])
        }
        let a = st("e", "a", 1, "A"), b = st("e", "b", 2, "B"), c = st("e", "c", 2, "A")
        #expect(a.merged(with: b) == b.merged(with: a))
        #expect(a.merged(with: b).merged(with: c) == a.merged(with: b.merged(with: c)))
        #expect(a.merged(with: a) == a)
        #expect(a.merged(with: b).merged(with: c).value("e", "x") == .string("b")) // device B > A at equal time
    }

    @Test func fractionalIndexesSortBetweenTheirNeighbours() {
        var keys = [FractionalIndex.between(nil, nil)]
        var g = RNG(s: 42)
        for _ in 0..<300 {
            let i = g.int(keys.count + 1)
            let k = FractionalIndex.between(i == 0 ? nil : keys[i - 1], i == keys.count ? nil : keys[i])
            if i > 0 { #expect(k > keys[i - 1]) }
            if i < keys.count { #expect(k < keys[i]) }
            #expect(!k.hasSuffix("0"))
            keys.insert(k, at: i)
        }
    }

    @Test func aClockThatIsBehindStillStampsAfterWhatItHasSeen() {
        var c = HLCClock(device: "slow")
        c.observe(HLC(wall: 10_000, counter: 3, device: "fast"))
        let s = c.tick(now: 5_000)
        #expect(s > HLC(wall: 10_000, counter: 3, device: "fast"))
    }
}

extension MutableCollection where Self: RandomAccessCollection {
    mutating func shuffle(using g: inout SyncConvergenceTests.RNG) {
        guard count > 1 else { return }
        for i in indices.reversed() { let j = index(startIndex, offsetBy: g.int(distance(from: startIndex, to: i) + 1)); swapAt(i, j) }
    }
}
extension Sequence {
    func shuffled(using g: inout SyncConvergenceTests.RNG) -> [Element] { var a = Array(self); a.shuffle(using: &g); return a }
}
