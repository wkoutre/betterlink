import Foundation
import Testing
@testable import BetterlinkCore

// A name given to a profile's group of Link Rules ("Uniswap" for Brave
// Profile 1): saved in rules.json, synced, and set from the command line.

private let diaID = "company.thebrowser.dia"
private let braveID = Browser.brave.bundleId
private let braveWork = ProfileRef(browser: braveID, directory: "Profile 1")
private let dia = ProfileRef(browser: diaID, directory: "Default")

@Suite struct RuleGroupNamesTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bl-names-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try! FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)
        return u
    }

    @Test func aNameIsSetReplacedAndRemoved() throws {
        var c = RuleStore.Contents()
        c.setGroupName("  Uniswap ", for: braveWork)
        #expect(c.groupName(braveWork) == "Uniswap")
        c.setGroupName("Work", for: braveWork)
        #expect(c.groupNames == [GroupName(browser: braveID, profile: "Profile 1", name: "Work")])
        c.setGroupName("", for: braveWork)
        #expect(c.groupName(braveWork) == nil && c.groupNames == [])
    }

    @Test func aFileWithoutNamesReadsAndWritesAsItDid() throws {
        let data = try JSONEncoder().encode(RuleStore.Contents())
        #expect(!String(decoding: data, as: UTF8.self).contains("groupNames"))
        let back = try JSONDecoder().decode(RuleStore.Contents.self, from: Data(#"{"version":1,"rules":[]}"#.utf8))
        #expect(back.groupNames == nil)
    }

    func mac(_ name: String, sync: URL, resolve: @escaping (String, String, ProfileIdentity) -> String?) throws -> SyncSession {
        let s = SettingsFolder(directory: tempDir())
        _ = try RuleStore(folder: s).update { _ in }
        return SyncSession(settings: s, folder: SyncFolder(sync), device: name, name: "Mac \(name)",
                           selection: SyncSelection(global: true),
                           identity: { ProfileIdentity(name: $0.directory == "Profile 1" ? "Uniswap" : "Primary", account: nil) },
                           resolve: resolve)
    }

    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }

    /// Work has Brave, where Profile 1 is the Uniswap profile; Personal has no
    /// Brave. A name given on either Mac reaches the other, and a Mac that
    /// can't find the profile keeps the name for the Macs that can.
    @Test func aNameSyncsBothWays() throws {
        let sync = tempDir()
        let personal = try mac("P", sync: sync) { _, d, _ in d }   // Brave not installed: kept as is
        // Work's Brave keeps the Uniswap profile in "Profile 2".
        let work = try mac("W", sync: sync) { b, d, who in b == braveID && who.name == "Uniswap" ? "Profile 2" : d }

        _ = try RuleStore(folder: personal.settings).update { $0.setGroupName("Uniswap", for: braveWork) }
        try personal.pull(now: t(1)); try work.pull(now: t(2))
        let workRef = ProfileRef(browser: braveID, directory: "Profile 2")
        #expect(try RuleStore(folder: work.settings).load().groupName(workRef) == "Uniswap")

        // Nothing moves after another round, and Work's folder name never replaces Personal's.
        try personal.pull(now: t(3)); try work.pull(now: t(4)); try personal.pull(now: t(5))
        #expect(try RuleStore(folder: personal.settings).load().groupNames == [GroupName(browser: braveID, profile: "Profile 1", name: "Uniswap")])

        // Renamed on Work, renamed on Personal.
        _ = try RuleStore(folder: work.settings).update { $0.setGroupName("Uni", for: workRef) }
        try work.pull(now: t(6)); try personal.pull(now: t(7))
        #expect(try RuleStore(folder: personal.settings).load().groupName(braveWork) == "Uni")

        // Removed on Personal, gone on Work.
        _ = try RuleStore(folder: personal.settings).update { $0.setGroupName("", for: braveWork) }
        try personal.pull(now: t(8)); try work.pull(now: t(9))
        #expect(try RuleStore(folder: work.settings).load().groupName(workRef) == nil)
        #expect(personal.state.value(SyncModel.globalID, "groupNames") == .null)
    }

    @Test func aMacWithoutTheProfileKeepsTheName() {
        // A synced name this Mac couldn't find goes out unchanged next to this Mac's own.
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let theirs = SyncModel.SyncedGroupName(browser: braveID, profile: "Profile 1", profileName: "Uniswap", name: "Uniswap")
        var state = SyncState()
        state.entities[SyncModel.globalID] = ["groupNames": Stamped(.string(String(decoding: try! enc.encode([theirs]), as: UTF8.self)),
                                                                    HLC(wall: 1, counter: 0, device: "A"))]
        let out = SyncModel.groupNamesField([GroupName(browser: diaID, profile: "Default", name: "Home")], state: state,
                                            applied: [SyncModel.groupNameKey(1): SyncModel.noProfile],
                                            identity: { _ in ProfileIdentity(name: "Primary", account: nil) })
        #expect(SyncModel.syncedGroupNames(out) == [theirs, SyncModel.SyncedGroupName(browser: diaID, profile: "Default", profileName: "Primary", name: "Home")])
    }

    @Test func theCommandNamesAGroup() throws {
        let f = SettingsFolder(directory: tempDir())
        var r = Rule(kind: .domain, pattern: "uniswap.org", browser: braveID, profile: "Profile 1")
        r.setTargets([braveWork])
        try RuleStore(folder: f).save(RuleStore.Contents(
            rules: [r], profiles: [BrowserProfile(browser: diaID, directory: "Default", name: "Primary", color: nil)]))
        // This Mac has no Brave: the profile is known only from the rule.
        let env = AgentEnvironment(folder: f, installed: [])
        func run(_ c: String, _ i: [String: Any] = [:]) -> AgentResponse { Agent.run(c, input: i, env: env) }

        #expect(run("rules.name", ["name": "Uniswap", "profile": "Profile 1", "browser": "Brave"]).error == nil)
        #expect(try RuleStore(folder: f).load().groupName(braveWork) == "Uniswap")
        let groups = try #require(run("rules.profiles").data as? [[String: Any]])
        #expect(groups.first?["name"] as? String == "Uniswap")
        // The current name finds the group too; "" removes it.
        #expect(run("rules.name", ["name": "", "profile": "Uniswap"]).error == nil)
        #expect(try RuleStore(folder: f).load().groupName(braveWork) == nil)
        #expect(run("rules.name", ["name": "X", "profile": "Nobody"]).error?.contains("No profile \"Nobody\"") == true)
        #expect(run("rules.name", ["profile": "Primary"]).error?.contains("Missing name") == true)
    }
}
