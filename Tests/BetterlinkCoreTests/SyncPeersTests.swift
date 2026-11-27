import Foundation
import Testing
@testable import BetterlinkCore

/// The other Macs in Sync settings, and the Link Rules page's mark on a rule
/// whose profile this Mac lacks (docs/sync.md).
struct SyncPeersTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bl-sync-peers-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func mac(_ name: String, sync: URL) throws -> SyncSession {
        let s = SettingsFolder(directory: tempDir())
        _ = try RuleStore(folder: s).update { _ in }
        return SyncSession(settings: s, folder: SyncFolder(sync), device: name, name: "Mac \(name)", selection: SyncSelection(global: true))
    }

    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }

    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    @Test func aPeerSaysWhenItLastSynced() {
        let now = utc.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 18))!
        let us = Locale(identifier: "en_US")
        func peer(_ synced: Date) -> SyncPeer { SyncPeer(device: "B", name: "Nick's Mac mini", synced: synced) }
        let today = peer(utc.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 15, minute: 12))!)
        let s = today.summary(now: now, calendar: utc, locale: us)
        #expect(s.hasPrefix("Nick's Mac mini, synced 3:12") && s.hasSuffix("PM"))
        let yesterday = peer(utc.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9, minute: 5))!)
        #expect(yesterday.summary(now: now, calendar: utc, locale: us).hasPrefix("Nick's Mac mini, synced yesterday at 9:05"))
        let older = peer(utc.date(from: DateComponents(year: 2026, month: 11, day: 20, hour: 9))!)
        #expect(older.summary(now: now, calendar: utc, locale: us) == "Nick's Mac mini, synced Nov 20")
        let lastYear = peer(utc.date(from: DateComponents(year: 2025, month: 12, day: 30, hour: 9))!)
        #expect(lastYear.summary(now: now, calendar: utc, locale: us) == "Nick's Mac mini, synced Dec 30, 2025")
    }

    @Test func aMacQuietForAWeekIsFlagged() {
        let now = t(30 * 86_400)
        #expect(SyncPeer(device: "B", name: "B", synced: now.addingTimeInterval(-6.9 * 86_400)).warning(now: now) == nil)
        let quiet = SyncPeer(device: "B", name: "B", synced: now.addingTimeInterval(-9.2 * 86_400))
        #expect(quiet.isStale(now: now))
        #expect(quiet.warning(now: now) == "hasn't synced in 9 days; it may be off or signed out of the sync folder")
        #expect(quiet.describe(now: now)["stale"] as? Bool == true)
    }

    @Test func thePeersAreTheOtherMacsFilesWithWhenTheyWrote() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        try b.pull(now: t(5))
        try a.pull(now: t(10))
        #expect(a.peers == [SyncPeer(device: "B", name: "Mac B", synced: t(5))])
        #expect(SyncFolder(sync).peers(except: "B") == [SyncPeer(device: "A", name: "Mac A", synced: t(10))])
    }

    /// An unchanged Mac rewrites its file once a day, so the others don't flag it.
    @Test func anIdleMacStillWritesOnceADay() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync)
        try a.pull(now: t(0))
        #expect(try a.push(now: t(3_600)) == false)
        #expect(try a.push(now: t(SyncSession.heartbeat + 1)) == true)
        #expect(SyncFolder(sync).peers(except: nil).first?.synced == t(SyncSession.heartbeat + 1))
        let again = SyncSession(settings: a.settings, folder: SyncFolder(sync), device: "A", name: "Mac A", selection: a.selection)
        #expect(try again.push(now: t(SyncSession.heartbeat + 60)) == false)  // a relaunch remembers when
    }

    @Test func aRuleWhoseProfileThisMacLacksIsMarked() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        b.resolve = { _, d, _ in d == "Here" ? d : nil }
        _ = try RuleStore(folder: a.settings).update {
            $0.rules = [Rule(kind: .domain, pattern: "work.com", browser: "c", profile: "Work"),
                        Rule(kind: .domain, pattern: "home.com", browser: "c", profile: "Here")]
        }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        let work = try RuleStore(folder: a.settings).load().rules[0].id
        #expect(b.localNotes.load().unresolvedRules == [work])
        let list = try #require(Agent.run("rules.list", input: [:], env: AgentEnvironment(folder: b.settings, installed: [])).data as? [[String: Any]])
        #expect(list.map { $0["unresolved"] as? Bool } == [true, false])
        // Pointed at a profile this Mac has, it is an ordinary rule again.
        _ = try RuleStore(folder: b.settings).update { $0.rules[0].profile = "Here" }
        try b.pull(now: t(3))
        #expect(b.localNotes.load().unresolvedRules == nil)
    }
}
