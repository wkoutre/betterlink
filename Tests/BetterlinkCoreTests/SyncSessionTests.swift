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
        try b.pull(now: t(1.5))  // B joins and takes A's
        #expect(try String(contentsOf: b.settings.configFile, encoding: .utf8) == "export default 'a'")
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

    // MARK: Review round 1 (F1–F4, F7)

    /// A Mac whose browser profiles are `dirs` (folder → signed-in account).
    func mac(_ name: String, sync: URL, dirs: [String: String]) throws -> SyncSession {
        let s = try mac(name, sync: sync)
        s.identity = { ProfileIdentity(name: nil, account: dirs[$0.directory]) }
        s.resolve = { _, _, who in dirs.first { $0.value == who.account }?.key }
        return s
    }

    @Test func theSameProfileInDifferentFoldersSettlesInsteadOfPingPonging() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, dirs: ["Profile 1": "work@x"])
        let b = try mac("B", sync: sync, dirs: ["Profile 2": "work@x"])
        _ = try RuleStore(folder: a.settings).update {
            $0.rules.append(Rule(kind: .domain, pattern: "github.com", browser: "c", profile: "Profile 1"))
            $0.fallback = ProfileRef(browser: "c", directory: "Profile 1")
        }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        #expect(try RuleStore(folder: b.settings).load().rules.first?.profile == "Profile 2")
        #expect(try RuleStore(folder: b.settings).load().fallback?.directory == "Profile 2")
        for i in 3...8 { try a.pull(now: t(Double(i))); try b.pull(now: t(Double(i) + 0.5)) }
        let settled = a.state
        try a.pull(now: t(9)); try b.pull(now: t(9.5))
        #expect(try a.push(now: t(10)) == false)
        #expect(try b.push(now: t(10)) == false)
        #expect(a.state == settled && b.state == settled)
        #expect(try RuleStore(folder: a.settings).load().rules.first?.profile == "Profile 1")
        #expect(try RuleStore(folder: a.settings).load().fallback?.directory == "Profile 1")
        #expect(try RuleStore(folder: b.settings).load().rules.first?.profile == "Profile 2")
    }

    @Test func aRuleForAProfileThisMacLacksOpensInTheFallbackAndStaysIntactElsewhere() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync, dirs: ["Profile 3": "work@x", "Default": "me@x"])
        // B's "Profile 3" is someone else's profile: it must not be used.
        let b = try mac("B", sync: sync, dirs: ["Profile 3": "other@x", "Default": "me@x"])
        _ = try RuleStore(folder: b.settings).update { $0.fallback = ProfileRef(browser: "c", directory: "Default") }
        try b.pull(now: t(0.5))
        _ = try RuleStore(folder: a.settings).update { $0.rules.append(Rule(kind: .domain, pattern: "corp.com", browser: "c", profile: "Profile 3")) }
        try a.pull(now: t(1))
        let r = try b.pull(now: t(2))
        #expect(r.notes.unresolvedRules.count == 1)
        #expect(try RuleStore(folder: b.settings).load().rules.first?.target == ProfileRef(browser: "c", directory: "Default"))
        try b.pull(now: t(3)); try a.pull(now: t(4))
        #expect(try RuleStore(folder: a.settings).load().rules.first?.profile == "Profile 3")
        #expect(a.state.value("rule:\(try RuleStore(folder: a.settings).load().rules.first!.id.uuidString)", "profileAccount") == .string("work@x"))
    }

    @Test func aMacJoiningLaterTakesTheSharedSettingsAndKeepsWhatIsOnlyItsOwn() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync)
        _ = try RuleStore(folder: a.settings).update {
            $0.fallback = ProfileRef(browser: "c", directory: "Work"); $0.showLog = true
            $0.rules.append(Rule(kind: .domain, pattern: "a.com", browser: "c", profile: "Work"))
        }
        try "export default 'a'".write(to: a.settings.configFile, atomically: true, encoding: .utf8)
        try a.pull(now: t(1))
        // B has been in use on its own: defaults, one rule of its own, its own config.ts.
        let b = try mac("B", sync: sync)
        _ = try RuleStore(folder: b.settings).update { $0.rules.append(Rule(kind: .domain, pattern: "b.com", browser: "c", profile: "Work")) }
        try "export default 'b'".write(to: b.settings.configFile, atomically: true, encoding: .utf8)
        try b.pull(now: t(100)); try a.pull(now: t(101))
        for s in [a, b] {
            let c = try RuleStore(folder: s.settings).load()
            #expect(c.fallback == ProfileRef(browser: "c", directory: "Work"))
            #expect(c.showLog == true)
            #expect(Set(c.rules.map(\.pattern)) == ["a.com", "b.com"])
            #expect(try String(contentsOf: s.settings.configFile, encoding: .utf8) == "export default 'a'")
        }
    }

    @Test func anUnreadableSidebarFileStopsTheSyncInsteadOfDeletingProfiles() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        try a.pull(now: t(1)); try b.pull(now: t(2))
        try "{ not json".write(to: a.settings.directory.appendingPathComponent("sidebar.json"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try a.pull(now: t(3)) }
        try b.pull(now: t(4))
        #expect(try SidebarStore(folder: b.settings).load().profiles.contains { $0.id == shared })
        #expect(b.state.isLive("sp:\(shared.uuidString)"))
    }

    @Test func aDeviceFileOthersCanChangeIsRefused() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync), b = try mac("B", sync: sync)
        _ = try RuleStore(folder: b.settings).update { $0.rules.append(Rule(kind: .domain, pattern: "evil.com", browser: "c", profile: "P")) }
        try b.pull(now: t(1))
        let f = SyncFolder(sync).file(for: "B")
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: f.path)
        let r = try a.pull(now: t(2))
        #expect(r.unsafe.count == 1 && r.unsafe[0].hasPrefix("B.json"))
        #expect(try RuleStore(folder: a.settings).load().rules.isEmpty)
    }
}
