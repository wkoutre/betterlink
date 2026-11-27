import Foundation
import Testing
@testable import BetterlinkCore

/// The delete guard and the history with Restore (docs/sync.md, Safety), on
/// simulated Macs: each its own settings folder, sharing one sync folder.
struct SyncSafetyTests {
    let shared = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!

    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bl-sync-safety-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func session(_ device: String, _ settings: SettingsFolder, _ sync: URL) -> SyncSession {
        SyncSession(settings: settings, folder: SyncFolder(sync), device: device, name: "Mac \(device)",
                    selection: SyncSelection(global: true, profiles: [shared: .init()]))
    }

    func mac(_ name: String, sync: URL) throws -> SyncSession {
        let s = SettingsFolder(directory: tempDir())
        _ = try SidebarStore(folder: s).update { $0 = SidebarLibrary(profiles: [SidebarProfile(id: shared, name: "Shared")]) }
        _ = try RuleStore(folder: s).update { _ in }
        return session(name, s, sync)
    }

    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }

    func addRules(_ patterns: [String], _ s: SyncSession) throws {
        _ = try RuleStore(folder: s.settings).update {
            for p in patterns { $0.rules.append(Rule(kind: .domain, pattern: p, browser: "b", profile: "P")) }
        }
    }

    func patterns(_ s: SyncSession) throws -> Set<String> { Set(try RuleStore(folder: s.settings).load().rules.map(\.pattern)) }

    /// A and B both hold `count` rules.
    func pair(rules count: Int) throws -> (SyncSession, SyncSession, URL) {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        try addRules((1...count).map { "r\($0).com" }, a)
        try a.pull(now: t(1)); try b.pull(now: t(2))
        #expect(try patterns(b).count == count)
        return (a, b, sync)
    }

    // MARK: The guard

    @Test func theGuardTripsAtFiveOrOverHalf() {
        #expect(!SyncGuard.trips(deleting: 0, live: 0, fresh: true))
        #expect(!SyncGuard.trips(deleting: 1, live: 1, fresh: false))   // one item, even the only one
        #expect(!SyncGuard.trips(deleting: 4, live: 20, fresh: false))
        #expect(SyncGuard.trips(deleting: 5, live: 100, fresh: false))
        #expect(SyncGuard.trips(deleting: 2, live: 3, fresh: false))    // over half of few
        #expect(!SyncGuard.trips(deleting: 2, live: 4, fresh: false))   // exactly half
        #expect(SyncGuard.trips(deleting: 1, live: 50, fresh: true))    // a new settings folder asks before any delete
    }

    @Test func deletingManyAtOnceIsHeldAndWritesNothing() throws {
        let (a, b, _) = try pair(rules: 6)
        let before = b.state
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeAll() }
        #expect(throws: SyncSession.Held.self) { try b.pull(now: t(3)) }
        let hold = try #require(b.held)
        #expect(hold.ids.count == 6 && !hold.fresh)
        #expect(hold.names == hold.names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })   // listed in order
        #expect(hold.reason.hasPrefix("This Mac would delete 6 synced items at once: Link Rule \u{201C}r"))
        #expect(hold.reason.hasSuffix("Sync is paused until you choose."))
        #expect(b.localNotes.load().held == hold)   // for the CLI
        #expect(b.state == before)                  // nothing recorded
        try a.pull(now: t(4))
        #expect(try patterns(a).count == 6)         // nothing reached A
        // Asking again changes nothing and keeps the same hold.
        #expect(throws: SyncSession.Held.self) { try b.pull(now: t(5)) }
        #expect(b.localNotes.load().held?.since == hold.since)
    }

    @Test func aFewDeletesGoThroughWithoutAsking() throws {
        let (a, b, _) = try pair(rules: 10)
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeLast(4) }
        try b.pull(now: t(3)); try a.pull(now: t(4))
        #expect(try patterns(a).count == 6)
        #expect(b.held == nil && b.localNotes.load().held == nil)
    }

    @Test func deletingMostOfAFewItemsAsks() throws {
        let (_, b, _) = try pair(rules: 2)   // with the Sidebar Profile, three synced items
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeAll() }
        #expect(throws: SyncSession.Held.self) { try b.pull(now: t(3)) }
    }

    /// The 2026-11-25 case: a copy with a fresh, empty settings folder that
    /// shares this Mac's sync preferences (and so its device id).
    @Test func aFreshSettingsFolderCantDeleteWhatIsShared() throws {
        let (a, _, sync) = try pair(rules: 1)
        _ = try SidebarStore(folder: a.settings).update { $0.update(shared) { $0.addFavorite(SavedLink(title: "Mail", url: "https://mail.example")) } }
        try a.pull(now: t(3))
        let empty = SettingsFolder(directory: tempDir())
        let copy = session("A", empty, sync)
        #expect(throws: SyncSession.Held.self) { try copy.pull(now: t(4)) }
        let hold = try #require(copy.held)
        #expect(hold.fresh && hold.ids.count >= 2)
        #expect(hold.reason.hasPrefix("This settings folder hasn't synced on this Mac before"))
        // The shared state is untouched: A still has everything.
        let fresh = session("A", a.settings, sync)
        #expect(fresh.state.isLive(try #require(fresh.state.entities.keys.first { $0.hasPrefix("rule:") })))
        try a.pull(now: t(5))
        #expect(try patterns(a) == ["r1.com"])
        #expect(try SidebarStore(folder: a.settings).load().profiles.first?.favorites.map(\.url) == ["https://mail.example"])
    }

    @Test func aFolderOrProfileCountsOnceWithWhatIsInIt() {
        var s = SyncState()
        let p = UUID().uuidString, f = UUID().uuidString, g = UUID().uuidString
        func set(_ id: String, _ fields: [String: SyncValue]) { s.entities[id] = fields.mapValues { Stamped($0, HLC(wall: 1, counter: 0, device: "A")) } }
        set("sp:\(p)", ["name": .string("Work")])
        set("node:\(f)", ["kind": .string("folder"), "profile": .string(p), "parent": .null])
        set("node:\(g)", ["kind": .string("folder"), "profile": .string("other"), "parent": .null])
        set("node:a", ["kind": .string("link"), "profile": .string("other"), "parent": .string(g)])
        set("node:b", ["kind": .string("link"), "profile": .string("other"), "parent": .null])
        set("rule:x", ["pattern": .string("x.com")])
        #expect(SyncSafety.roots(["node:\(g)", "node:a"], in: s) == ["node:\(g)"])
        #expect(SyncSafety.roots(["sp:\(p)", "node:\(f)"], in: s) == ["sp:\(p)"])
        #expect(SyncSafety.roots(["node:a", "node:b", "rule:x"], in: s).count == 3)  // the folder stays: each counts
    }

    @Test func deletingABigFolderOnPurposeDoesntAsk() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        try addRules(["one.com", "two.com"], a)
        _ = try SidebarStore(folder: a.settings).update { $0.update(shared) {
            $0.items = [.folder(SidebarFolder(id: UUID(), name: "Big", items: (1...8).map { .link(SavedLink(title: "L\($0)", url: "https://l\($0).example")) }))]
        } }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        _ = try SidebarStore(folder: b.settings).update { $0.update(shared) { $0.items = [] } }
        try b.pull(now: t(3)); try a.pull(now: t(4))
        #expect(b.held == nil)
        #expect(try SidebarStore(folder: a.settings).load().profiles.first?.items.isEmpty == true)
        #expect(try patterns(a) == ["one.com", "two.com"])
    }

    @Test func deletingASidebarProfileWithItsItemsDoesntAsk() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        let extra = UUID()
        for s in [a, b] { s.selection.profiles[extra] = .init() }
        try addRules(["one.com", "two.com"], a)
        _ = try SidebarStore(folder: a.settings).update { $0.profiles.append(SidebarProfile(id: extra, name: "Extra",
            favorites: (1...6).map { SavedLink(title: "F\($0)", url: "https://f\($0).example") })) }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        #expect(try SidebarStore(folder: b.settings).load().profiles.contains { $0.id == extra })
        _ = try SidebarStore(folder: b.settings).update { $0.profiles.removeAll { $0.id == extra } }
        try b.pull(now: t(3)); try a.pull(now: t(4))
        #expect(b.held == nil)
        #expect(!(try SidebarStore(folder: a.settings).load().profiles.contains { $0.id == extra }))
    }

    /// A Mac that synced before sync-local.json existed: its settings are
    /// there, so the first sync after the update writes the marker and doesn't ask.
    @Test func anUpdatedMacWithSettingsButNoNotesDoesntAsk() throws {
        let (a, b, sync) = try pair(rules: 3)
        try FileManager.default.removeItem(at: b.localNotes.file)
        let again = session("B", b.settings, sync)   // relaunch after the update
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeLast() }
        try again.pull(now: t(3)); try a.pull(now: t(4))
        #expect(again.held == nil)
        #expect(again.localNotes.load().device == "B")
        #expect(try patterns(a).count == 2)
    }

    @Test func notesFromAnotherDeviceStillCountAsFresh() throws {
        let (a, b, _) = try pair(rules: 3)
        try b.localNotes.update { $0.device = "someone-else" }
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeLast() }
        #expect(throws: SyncSession.Held.self) { try b.pull(now: t(3)) }
        #expect(b.held?.fresh == true)
        try a.pull(now: t(4))
        #expect(try patterns(a).count == 3)
    }

    /// The incident again, with a starter sidebar.json already in the new
    /// folder: it isn't fresh by the marker rule, but it would leave this
    /// Mac with no rules, which the shared state has two of.
    @Test func anEmptyFolderWithAStarterSidebarStillCantWipeTheRules() throws {
        let (a, _, sync) = try pair(rules: 2)
        let empty = SettingsFolder(directory: tempDir())
        _ = try SidebarStore(folder: empty).update { $0 = SidebarLibrary(profiles: [SidebarProfile(id: UUID(), name: "Primary")]) }
        let copy = session("A", empty, sync)
        #expect(throws: SyncSession.Held.self) { try copy.pull(now: t(3)) }
        #expect(copy.held?.fresh == false)
        try a.pull(now: t(4))
        #expect(try patterns(a) == ["r1.com", "r2.com"])
    }

    @Test func removingEverySyncedProfileAsksWhateverTheCount() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        let extra = UUID()
        for s in [a, b] { s.selection.profiles[extra] = .init() }
        try addRules((1...10).map { "r\($0).com" }, a)
        _ = try SidebarStore(folder: a.settings).update { $0.profiles.append(SidebarProfile(id: extra, name: "Extra")) }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        _ = try SidebarStore(folder: b.settings).update { $0.profiles = [SidebarProfile(id: UUID(), name: "Starter")] }
        #expect(throws: SyncSession.Held.self) { try b.pull(now: t(3)) }   // two roots of twelve would not ask
        #expect(b.held?.ids.count == 2)
    }

    @Test func deletingTheOnlyRuleDoesntNag() throws {
        let (a, b, _) = try pair(rules: 1)
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeAll() }
        try b.pull(now: t(3)); try a.pull(now: t(4))
        #expect(b.held == nil)
        #expect(try patterns(a).isEmpty)
        #expect(!SyncSafety.wipesAKind(before: b.state, after: b.state, scope: { _ in true }))
    }

    @Test func deleteThemEverywhereProceedsOnceThenAsksAgain() throws {
        let (a, b, _) = try pair(rules: 8)
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeLast(6) }
        #expect(throws: SyncSession.Held.self) { try b.pull(now: t(3)) }
        let hold = try #require(b.held)
        try b.localNotes.update { $0.decision = SyncDecision(choice: .delete, ids: hold.ids) }
        try b.pull(now: t(4)); try a.pull(now: t(5))
        #expect(try patterns(a) == ["r1.com", "r2.com"])
        #expect(b.localNotes.load().decision == nil && b.localNotes.load().held == nil)
        // The answer was for those six only.
        let (c, d, _) = try pair(rules: 8)
        _ = try RuleStore(folder: d.settings).update { $0.rules.removeLast(6) }
        #expect(throws: SyncSession.Held.self) { try d.pull(now: t(3)) }
        let first = try #require(d.held)
        try d.localNotes.update { $0.decision = SyncDecision(choice: .delete, ids: Array(first.ids.prefix(5))) }
        #expect(throws: SyncSession.Held.self) { try d.pull(now: t(4)) }
        try c.pull(now: t(5))
        #expect(try patterns(c).count == 8)
    }

    @Test func keepThemBringsTheSharedItemsBack() throws {
        let (a, b, _) = try pair(rules: 6)
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeAll() }
        #expect(throws: SyncSession.Held.self) { try b.pull(now: t(3)) }
        let hold = try #require(b.held)
        try b.localNotes.update { $0.decision = SyncDecision(choice: .keep, ids: hold.ids) }
        let r = try b.pull(now: t(4))
        #expect(r.keepDone)
        #expect(try patterns(b).count == 6)
        #expect(b.held == nil && b.localNotes.load().decision == nil && b.localNotes.load().held == nil)
        try a.pull(now: t(5)); try b.pull(now: t(6))
        #expect(try patterns(a).count == 6)
        #expect(a.state == b.state)
    }

    @Test func aFreshFolderThatKeepsTakesEverythingShared() throws {
        let (_, b, sync) = try pair(rules: 2)
        let copy = session("A", SettingsFolder(directory: tempDir()), sync)
        #expect(throws: SyncSession.Held.self) { try copy.pull(now: t(3)) }
        try copy.localNotes.update { $0.decision = SyncDecision(choice: .keep, ids: copy.held!.ids) }
        try copy.pull(now: t(4))
        #expect(try patterns(copy) == ["r1.com", "r2.com"])
        #expect(copy.localNotes.load().device == "A")
        // From now on it is an ordinary folder: one delete needs no answer.
        _ = try RuleStore(folder: copy.settings).update { $0.rules.removeLast() }
        try copy.pull(now: t(5)); try b.pull(now: t(6))
        #expect(try patterns(b) == ["r1.com"])
    }

    // MARK: History and Restore

    @Test func theHistoryIsCappedByCountAndAge() {
        var notes = SyncLocal()
        let now = t(100 * 86_400)
        func entry(_ daysAgo: Double) -> SyncHistoryEntry {
            SyncHistoryEntry(date: now.addingTimeInterval(-daysAgo * 86_400), batch: UUID(), entity: "rule:x", kind: .deleted,
                             what: "Link Rule", from: "Mac B", previous: [:])
        }
        notes.record([entry(40), entry(31)], now: now)
        #expect(notes.history.isEmpty)   // older than 30 days
        notes.record((0..<60).map { _ in entry(1) }, now: now)
        #expect(notes.history.count == SyncLocal.historyLimit)
        let newest = entry(0)
        notes.record([newest], now: now)
        #expect(notes.history.first == newest && notes.history.count == 50)
    }

    @Test func aDeleteAndAnEditFromAnotherMacAreRecordedAndRestoreWins() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        try addRules(["old.com", "other.com"], a)
        _ = try SidebarStore(folder: a.settings).update { $0.update(shared) { $0.addFavorite(SavedLink(title: "Mail", url: "https://mail.example")) } }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        // A renames a rule and deletes the favorite.
        _ = try RuleStore(folder: a.settings).update { c in c.rules = c.rules.map { var r = $0; if r.pattern == "old.com" { r.pattern = "new.com" }; return r } }
        _ = try SidebarStore(folder: a.settings).update { $0.update(shared) { $0.favorites.removeAll() } }
        try a.pull(now: t(3))
        let r = try b.pull(now: t(4))
        #expect(r.recorded.count == 2)
        let history = b.localNotes.load().history
        let deleted = try #require(history.first { $0.kind == .deleted })
        let changed = try #require(history.first { $0.kind == .changed })
        #expect(deleted.summary == "Favorite \u{201C}Mail\u{201D} was deleted on Mac A.")
        #expect(deleted.previous["url"] == .string("https://mail.example"))
        #expect(changed.summary == "Link Rule \u{201C}old.com\u{201D}: pattern changed on Mac A.")
        #expect(changed.previous == ["pattern": .string("old.com")])
        #expect(try patterns(b) == ["new.com", "other.com"])

        // Restore both on B: a new edit there, so it wins on A too.
        try b.localNotes.update { $0.restore = [deleted.id, changed.id] }
        let back = try b.pull(now: t(5))
        #expect(back.restored.count == 2)
        #expect(try patterns(b) == ["old.com", "other.com"])
        #expect(try SidebarStore(folder: b.settings).load().profiles.first?.favorites.map(\.url) == ["https://mail.example"])
        #expect(b.localNotes.load().restore.isEmpty)
        #expect(!b.localNotes.load().history.contains { $0.id == deleted.id || $0.id == changed.id })
        let onA = try a.pull(now: t(6)); try b.pull(now: t(7))
        #expect(try patterns(a) == ["old.com", "other.com"])
        #expect(try SidebarStore(folder: a.settings).load().profiles.first?.favorites.map(\.url) == ["https://mail.example"])
        #expect(a.state == b.state)
        // A sees B's restore as an edit from B, with a Restore of its own.
        #expect(onA.recorded.map(\.kind) == [.changed])
        #expect(a.localNotes.load().history.first?.from == "Mac B")
    }

    @Test func restoringADeletedFolderBringsBackWhatWasInIt() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        try addRules((1...6).map { "keep\($0).com" }, a)   // enough synced items that three deletes don't ask
        let folder = UUID()
        _ = try SidebarStore(folder: a.settings).update { $0.update(shared) {
            $0.items = [.folder(SidebarFolder(id: folder, name: "Reading", items: [
                .link(SavedLink(title: "One", url: "https://one.example")), .link(SavedLink(title: "Two", url: "https://two.example")),
            ]))]
        } }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        _ = try SidebarStore(folder: a.settings).update { $0.update(shared) { $0.items = [] } }
        try a.pull(now: t(3)); try b.pull(now: t(4))
        let history = b.localNotes.load().history
        #expect(history.count == 3)
        let entry = try #require(history.first { $0.what == "folder \u{201C}Reading\u{201D}" })
        try b.localNotes.update { $0.restore = [entry.id] }
        try b.pull(now: t(5)); try a.pull(now: t(6))
        for s in [a, b] {
            let items = try #require(try SidebarStore(folder: s.settings).load().profiles.first?.items)
            guard case .folder(let f) = try #require(items.first) else { Issue.record("no folder"); continue }
            #expect(f.name == "Reading" && f.items.count == 2)
        }
        #expect(b.localNotes.load().history.isEmpty)
    }

    @Test func thisMacsOwnEditsAreNotRecorded() throws {
        let (a, _, _) = try pair(rules: 3)
        _ = try RuleStore(folder: a.settings).update { $0.rules.removeLast() }
        try a.pull(now: t(3))
        #expect(a.localNotes.load().history.isEmpty)
    }

    // MARK: The command

    @Test func theCommandShowsTheHoldAndRecordsTheAnswer() throws {
        let (_, b, _) = try pair(rules: 6)
        let env = AgentEnvironment(folder: b.settings, installed: [])
        func run(_ c: String, _ input: [String: Any] = [:]) -> AgentResponse { Agent.run(c, input: input, env: env) }
        #expect((run("sync.paused").data as? [String: Any])?["paused"] as? Bool == false)
        #expect(!run("sync.resolve", ["choice": "keep"]).ok)   // nothing to answer
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeAll() }
        #expect(throws: SyncSession.Held.self) { try b.pull(now: t(3)) }
        let paused = try #require(run("sync.paused").data as? [String: Any])
        #expect(paused["paused"] as? Bool == true && (paused["items"] as? [String])?.count == 6)
        #expect(!run("sync.resolve", ["choice": "maybe"]).ok)
        #expect(run("sync.resolve", ["choice": "keep"]).ok)
        #expect(b.localNotes.load().decision?.keep.isEmpty == false)
        try b.pull(now: t(4))
        #expect(try patterns(b).count == 6)
        #expect((run("sync.paused").data as? [String: Any])?["paused"] as? Bool == false)
    }

    @Test func theCommandListsAndRestoresHistory() throws {
        let (a, b, _) = try pair(rules: 4)
        _ = try RuleStore(folder: a.settings).update { $0.rules.removeLast() }
        try a.pull(now: t(3)); try b.pull(now: t(4))
        let env = AgentEnvironment(folder: b.settings, installed: [])
        let list = try #require(Agent.run("sync.history", input: [:], env: env).data as? [[String: Any]])
        let id = try #require(list.first?["id"] as? String)
        #expect(list.first?["summary"] as? String == "Link Rule \u{201C}r4.com\u{201D} was deleted on Mac A.")
        #expect(!Agent.run("sync.restore", input: ["id": "zzz"], env: env).ok)
        #expect(Agent.run("sync.restore", input: ["id": String(id.prefix(8))], env: env).ok)
        try b.pull(now: t(5)); try a.pull(now: t(6))
        #expect(try patterns(a).count == 4)
    }

    // MARK: Review round 1

    /// B1: a fresh settings folder (the shared device id, nothing in it)
    /// sends no empty config.ts, fallback or Show log, with or without a hold.
    @Test(arguments: [false, true])
    func aFreshFolderNeverChangesConfigOrGlobalSettings(holdAndKeep: Bool) throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        try "export default 'a'".write(to: a.settings.configFile, atomically: true, encoding: .utf8)
        _ = try RuleStore(folder: a.settings).update {
            $0.fallback = ProfileRef(browser: "b", directory: "P"); $0.showLog = true
            if holdAndKeep { for p in ["one.com", "two.com"] { $0.rules.append(Rule(kind: .domain, pattern: p, browser: "b", profile: "P")) } }
        }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        // Without the hold, only the global settings sync on the copy: nothing it lacks can be deleted.
        let copy = SyncSession(settings: SettingsFolder(directory: tempDir()), folder: SyncFolder(sync), device: "A", name: "Mac A",
                               selection: holdAndKeep ? a.selection : SyncSelection(global: true))
        if holdAndKeep {
            #expect(throws: SyncSession.Held.self) { try copy.pull(now: t(3)) }
            try copy.localNotes.update { $0.answer(.keep) }
        }
        try copy.pull(now: t(4))
        try b.pull(now: t(5)); try a.pull(now: t(6))
        for s in [a, b, copy] {
            let r = try RuleStore(folder: s.settings).load()
            #expect(try String(contentsOf: s.settings.configFile, encoding: .utf8) == "export default 'a'")
            #expect(r.fallback == ProfileRef(browser: "b", directory: "P"))
            #expect(r.showLog == true)
            #expect(r.rules.count == (holdAndKeep ? 2 : 0))
        }
        let baks = try FileManager.default.contentsOfDirectory(atPath: a.settings.directory.path).filter { $0.hasSuffix(".bak") }
        #expect(baks.isEmpty)
        #expect(copy.localNotes.load().history.isEmpty)   // a first sync isn't news
    }

    /// M1: a change that changes nothing writes no notes file, so an updated
    /// Mac doesn't turn fresh; notes with no device count as none.
    @Test func aNoOpNeverCreatesTheNotesFile() throws {
        let (a, b, _) = try pair(rules: 3)
        try FileManager.default.removeItem(at: b.localNotes.file)
        try b.localNotes.update { $0.held = nil }
        #expect(!FileManager.default.fileExists(atPath: b.localNotes.file.path))
        #expect(!Agent.run("sync.resolve", input: ["choice": "keep"], env: AgentEnvironment(folder: b.settings, installed: [])).ok)
        #expect(!FileManager.default.fileExists(atPath: b.localNotes.file.path))
        try SettingsFile.write(SyncLocal(), to: b.localNotes.file, what: "sync-local.json")   // notes, but no device
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeLast() }
        try b.pull(now: t(3)); try a.pull(now: t(4))
        #expect(b.held == nil)
        #expect(try patterns(a).count == 2)
    }

    /// M4: answering a second hold keeps the answer to the first.
    @Test func answersForDifferentItemsAddUp() {
        var d = SyncDecision(choice: .keep, ids: ["rule:x"])
        d.add(.delete, ["rule:y"])
        #expect(d == SyncDecision(keep: ["rule:x"], delete: ["rule:y"]))
        d.add(.delete, ["rule:x"])
        #expect(d == SyncDecision(keep: [], delete: ["rule:x", "rule:y"]))
        #expect(d.choice(for: ["rule:y"]) == .delete && d.choice(for: ["rule:z"]) == nil)
    }

    /// M8: a Mac joining keeps nothing of its own that differs, and that isn't history.
    @Test func joiningRecordsNoHistory() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        try addRules(["one.com"], a)
        try a.pull(now: t(1))
        _ = try SidebarStore(folder: b.settings).update { $0.update(shared) { $0.name = "Mine" } }
        let r = try b.pull(now: t(2))
        #expect(try SidebarStore(folder: b.settings).load().profiles.first?.name == "Shared")
        #expect(r.recorded.isEmpty && b.localNotes.load().history.isEmpty)
    }

    /// M5: restoring a link also restores the Sidebar Profile the same sync deleted.
    @Test func restoringAnItemBringsBackWhatItWasIn() {
        let batch = UUID(), p = UUID().uuidString
        let profile = SyncHistoryEntry(date: t(0), batch: batch, entity: "sp:\(p)", kind: .deleted, what: "Sidebar Profile", from: "B",
                                       previous: ["name": .string("Work")])
        let link = SyncHistoryEntry(date: t(0), batch: batch, entity: "node:l", kind: .deleted, what: "saved link", from: "B",
                                    previous: ["profile": .string(p), "parent": .null])
        let other = SyncHistoryEntry(date: t(0), batch: batch, entity: "node:m", kind: .deleted, what: "saved link", from: "B",
                                     previous: ["profile": .string(p)])
        let picked = SyncSafety.restoring([link.id], from: [profile, link, other])
        #expect(Set(picked.map(\.entity)) == ["node:l", "sp:\(p)"])
    }
}
