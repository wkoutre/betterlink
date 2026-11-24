import Foundation
import Testing
@testable import BetterlinkCore

/// The CLI, an editor or the app writing a settings file while a sync runs
/// (PR 23 review M1): the write must survive, and must not revert what
/// another Mac changed.
struct SyncRaceTests {
    let shared = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!

    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bl-race-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return u
    }

    func mac(_ name: String, _ sync: URL) throws -> SyncSession {
        let s = SettingsFolder(directory: tempDir())
        _ = try SidebarStore(folder: s).update { $0 = SidebarLibrary(profiles: [SidebarProfile(id: shared, name: "Shared")]) }
        _ = try RuleStore(folder: s).update { _ in }
        return SyncSession(settings: s, folder: SyncFolder(sync), device: name, name: name,
                           selection: SyncSelection(global: true, profiles: [shared: .init()]))
    }

    /// Two Macs in step, then B changes a rule, a saved link and the shared
    /// profile's name, so A's next pull has something to write everywhere.
    func pair() throws -> (a: SyncSession, b: SyncSession) {
        let sync = tempDir()
        let a = try mac("A", sync), b = try mac("B", sync)
        try a.pull(); try b.pull(); try a.pull()
        _ = try RuleStore(folder: b.settings).update { $0.rules.append(Rule(kind: .domain, pattern: "b.example", browser: "c", profile: "P")) }
        _ = try SidebarStore(folder: b.settings).update { $0.update(shared) { $0.name = "Renamed on B"; $0.addLink(SavedLink(title: "B", url: "https://b.example")) } }
        try b.pull()
        return (a, b)
    }

    func addLink(_ url: String, _ s: SyncSession) {
        #expect(Agent.run("sidebar.links.add", input: ["url": url], env: AgentEnvironment(folder: s.settings, installed: [])).ok)
    }
    func addRule(_ pattern: String, _ s: SyncSession) throws {
        _ = try RuleStore(folder: s.settings).update { $0.rules.append(Rule(kind: .domain, pattern: pattern, browser: "c", profile: "P")) }
    }

    func expectSettled(_ a: SyncSession, _ b: SyncSession, links: Set<String>, rules: Set<String>) throws {
        for _ in 0..<2 { try a.pull(); try b.pull() }
        for s in [a, b] {
            let p = try #require(try SidebarStore(folder: s.settings).load().profiles.first { $0.id == shared })
            #expect(Set(p.allLinks.map(\.url)) == links)
            #expect(p.name == "Renamed on B") // the race must not revert the other Mac
            #expect(Set(try RuleStore(folder: s.settings).load().rules.map(\.pattern)) == rules)
        }
        #expect(a.state == b.state)
    }

    @Test func aLinkAddedWhilePullRunsIsKept() throws {
        let (a, b) = try pair()
        var once = true
        a.resolve = { _, d, _ in if once { once = false; addLink("https://agent.example", a) }; return d }
        try a.pull()
        #expect(!once)
        try expectSettled(a, b, links: ["https://b.example", "https://agent.example"], rules: ["b.example"])
    }

    @Test func aRuleAddedWhilePullRunsIsKept() throws {
        let (a, b) = try pair()
        var once = true
        a.resolve = { _, d, _ in if once { once = false; try? addRule("agent.example", a) }; return d }
        try a.pull()
        #expect(!once)
        try expectSettled(a, b, links: ["https://b.example"], rules: ["b.example", "agent.example"])
    }

    @Test func aLinkAddedWhileLocalEditsAreRecordedIsKeptWithNoOtherMac() throws {
        let a = try mac("A", tempDir())
        try addRule("mine.example", a)
        var once = true
        a.identity = { r in if once { once = false; addLink("https://agent.example", a) }; return ProfileIdentity(name: r.directory, account: nil) }
        try a.pull(); try a.pull()
        #expect(!once)
        #expect(try SidebarStore(folder: a.settings).load().profiles[0].allLinks.map(\.url) == ["https://agent.example"])
    }

    @Test func aConfigSavedWhilePullRunsIsKept() throws {
        let (a, b) = try pair()
        try "export default 'b'".write(to: b.settings.configFile, atomically: true, encoding: .utf8)
        try b.pull()
        var once = true
        a.resolve = { _, d, _ in
            if once { once = false; try? "export default 'mine'".write(to: a.settings.configFile, atomically: true, encoding: .utf8) }
            return d
        }
        try a.pull(); try b.pull()
        #expect(!once)
        // Saved after B's, so it is the newer one on both Macs.
        for s in [a, b] { #expect(try String(contentsOf: s.settings.configFile, encoding: .utf8) == "export default 'mine'") }
    }

    /// A pull that can't write keeps nothing it read, so the next one doesn't
    /// stamp this Mac's old values as new edits over the other Mac's.
    @Test func aPullThatCantWriteDoesNotRevertTheOtherMac() throws {
        let (a, b) = try pair()
        let dir = a.settings.directory.path
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir)
        #expect(throws: (any Error).self) { try a.pull() }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        try expectSettled(a, b, links: ["https://b.example"], rules: ["b.example"])
    }

    /// An agent adding links for a while, with syncs running all along.
    @Test func everyLinkAnAgentAddsDuringSyncsIsKept() throws {
        let sync = tempDir()
        let a = try mac("A", sync), b = try mac("B", sync)
        try a.pull(); try b.pull()
        let n = 40, settings = a.settings
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            for i in 0..<n {
                _ = Agent.run("sidebar.links.add", input: ["url": "https://new\(i).example"], env: AgentEnvironment(folder: settings, installed: []))
                usleep(5_000)
            }
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut { _ = try? a.pull(); try b.pull() }
        try a.pull(); try b.pull()
        for s in [a, b] { #expect(try SidebarStore(folder: s.settings).load().profiles.first { $0.id == shared }?.allLinks.count == n) }
    }
}
