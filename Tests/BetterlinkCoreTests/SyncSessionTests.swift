import Foundation
import Testing
@testable import BetterlinkCore

/// Two Macs, each with its own settings folder, sharing one sync folder.
struct SyncSessionTests {
    let shared = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bl-sync-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func mac(_ name: String, sync: URL) throws -> SyncSession {
        let s = SettingsFolder(directory: tempDir())
        _ = try SidebarStore(folder: s).update { $0 = SidebarLibrary(profiles: [SidebarProfile(id: shared, name: "Shared")]) }
        _ = try RuleStore(folder: s).update { _ in }
        return SyncSession(settings: s, folder: SyncFolder(sync), device: name, name: "Mac \(name)",
                           selection: SyncSelection(global: true, profiles: [shared: .init()]))
    }

    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }

    @Test func aChangeOnOneMacArrivesOnTheOther() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        _ = try RuleStore(folder: a.settings).update { $0.rules.append(Rule(kind: .domain, pattern: "github.com", browser: "b", profile: "Work")) }
        _ = try SidebarStore(folder: a.settings).update { $0.update(shared) { $0.addFavorite(SavedLink(title: "Mail", url: "https://mail.example")) } }
        try a.pull(now: t(1))
        let r = try b.pull(now: t(2))
        #expect(r.changedSettings)
        #expect(try RuleStore(folder: b.settings).load().rules.map(\.pattern) == ["github.com"])
        #expect(try SidebarStore(folder: b.settings).load().profiles.first?.favorites.map(\.url) == ["https://mail.example"])
    }

    @Test func editsOnBothMacsAtOnceBothSurviveAndConverge() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        _ = try RuleStore(folder: a.settings).update { $0.rules.append(Rule(kind: .domain, pattern: "a.com", browser: "b", profile: "P")) }
        _ = try RuleStore(folder: b.settings).update { $0.rules.append(Rule(kind: .domain, pattern: "b.com", browser: "b", profile: "P")) }
        try a.pull(now: t(1)); try b.pull(now: t(1))   // neither has seen the other yet
        try a.pull(now: t(2)); try b.pull(now: t(3)); try a.pull(now: t(4))
        let ra = try RuleStore(folder: a.settings).load().rules, rb = try RuleStore(folder: b.settings).load().rules
        #expect(Set(ra.map(\.pattern)) == ["a.com", "b.com"])
        #expect(ra == rb)
        #expect(a.state == b.state)
    }

    @Test func aDeleteOnOneMacRemovesItEverywhere() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        _ = try RuleStore(folder: a.settings).update { $0.rules.append(Rule(kind: .domain, pattern: "gone.com", browser: "b", profile: "P")) }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        _ = try RuleStore(folder: b.settings).update { $0.rules.removeAll() }
        try b.pull(now: t(3)); try a.pull(now: t(4))
        #expect(try RuleStore(folder: a.settings).load().rules.isEmpty)
    }

    @Test func theNewerConfigWinsAndTheOtherIsKept() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        try "export default 'a'".write(to: a.settings.configFile, atomically: true, encoding: .utf8)
        try a.pull(now: t(1))
        try "export default 'b'".write(to: b.settings.configFile, atomically: true, encoding: .utf8)
        try b.pull(now: t(2))   // B's edit is newer
        let r = try a.pull(now: t(3))
        #expect(try String(contentsOf: a.settings.configFile, encoding: .utf8) == "export default 'b'")
        let bak = try #require(r.configReplaced)
        #expect(try String(contentsOf: bak, encoding: .utf8) == "export default 'a'")
    }

    @Test func unreadableAndNewerFilesAreSkipped() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync)
        try a.pull(now: t(1))
        let f = SyncFolder(sync)
        try "{\"format\": 1, \"device\": \"half".write(to: f.devices.appendingPathComponent("C.json"), atomically: true, encoding: .utf8)
        try "{\"format\": 2, \"device\": \"D\"}".write(to: f.devices.appendingPathComponent("D.json"), atomically: true, encoding: .utf8)
        let r = try a.pull(now: t(2))
        #expect(r.skipped == ["C.json"])
        #expect(r.newer == ["D.json"])
    }

    @Test func anUnsyncedProfileNeverLeavesThisMac() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        let privateID = UUID()
        _ = try SidebarStore(folder: a.settings).update { $0.profiles.append(SidebarProfile(id: privateID, name: "Private",
                                                                                              favorites: [SavedLink(title: "x", url: "https://x.example")])) }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        #expect(!(try SidebarStore(folder: b.settings).load().profiles.contains { $0.id == privateID }))
        let raw = try String(contentsOf: SyncFolder(sync).file(for: "A"), encoding: .utf8)
        #expect(!raw.contains(privateID.uuidString) && !raw.contains("x.example"))
    }

    @Test func theStateSurvivesARelaunch() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync)
        _ = try RuleStore(folder: a.settings).update { $0.rules.append(Rule(kind: .domain, pattern: "kept.com", browser: "b", profile: "P")) }
        try a.pull(now: t(1))
        let again = SyncSession(settings: a.settings, folder: SyncFolder(sync), device: "A", name: "Mac A", selection: a.selection)
        #expect(again.state == a.state)
        #expect(try again.push(now: t(2)) == false) // nothing new to write
    }
}
