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

    // MARK: config.ts (re-review)

    func config(_ s: SyncSession) -> String? { try? String(contentsOf: s.settings.configFile, encoding: .utf8) }
    func write(_ text: String, _ s: SyncSession) throws { try text.write(to: s.settings.configFile, atomically: true, encoding: .utf8) }
    /// Everything config.ts and its backups hold.
    func kept(_ s: SyncSession) -> Set<String> {
        let dir = s.settings.directory
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("config.ts") }
        return Set(names.compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) })
    }

    @Test func aConfigSavedAtAnyMomentIsNeverLost() throws {
        let sync = tempDir()
        let a = try mac("A", sync), b = try mac("B", sync)
        try write("start", a); try a.pull(); try b.pull()
        let file = a.settings.configFile
        var lost = 0
        // SYNC_RACE_N: more rounds, to look for rare losses (about 1 in 10,000 saves once).
        for i in 0..<(Int(ProcessInfo.processInfo.environment["SYNC_RACE_N"] ?? "") ?? 400) {
            try write("b\(i)", b); try b.pull()
            let mine = "editor\(i)"
            let done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                usleep(UInt32.random(in: 0..<6_000))
                if i % 2 == 0 {
                    // As most editors save: a new file, renamed over the old one.
                    let temp = file.deletingLastPathComponent().appendingPathComponent("editor-\(i)")
                    try! Data(mine.utf8).write(to: temp)
                    if rename(temp.path, file.path) != 0 { Issue.record("the editor's save failed: \(errno)") }
                } else {
                    // Foundation's, which follows a file that is moved under it.
                    do { try mine.write(to: file, atomically: true, encoding: .utf8) } catch { Issue.record("the save failed: \(error)") }
                }
                done.signal()
            }
            _ = try? a.pull()
            done.wait()
            if !kept(a).contains(mine) {
                lost += 1
                Issue.record("lost \(mine)")
            }
            try a.pull(); try b.pull()
        }
        #expect(lost == 0)
    }

    @Test func anUnreadableConfigStopsTheSyncInsteadOfCountingAsDeleted() throws {
        let sync = tempDir()
        let a = try mac("A", sync), b = try mac("B", sync)
        try write("shared", a); try a.pull(); try b.pull()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: a.settings.configFile.path)
        #expect(throws: (any Error).self) { try a.pull() }
        try b.pull()
        #expect(config(b) == "shared")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a.settings.configFile.path)
        try a.pull()
        #expect(config(a) == "shared")
    }

    @Test func aConfigThatIsntTextIsLeftAloneByAMacJoining() throws {
        let sync = tempDir()
        let a = try mac("A", sync)
        try write("shared", a); try a.pull()
        let b = try mac("B", sync)
        let bytes = Data([0xFF, 0xFE, 0x00, 0xC3, 0x28])
        try bytes.write(to: b.settings.configFile)
        #expect(throws: (any Error).self) { try b.pull() }
        #expect(try Data(contentsOf: b.settings.configFile) == bytes)
    }

    @Test func twoReplacementsInOneSecondKeepTwoBackups() throws {
        let sync = tempDir()
        let a = try mac("A", sync), b = try mac("B", sync)
        try write("precious", a); try a.pull(); try b.pull()
        let now = Date().addingTimeInterval(60)
        for text in ["b1", "b2"] {
            try write(text, b)
            try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: b.settings.configFile.path)
            try b.pull(); try a.pull(now: now)
        }
        #expect(config(a) == "b2")
        #expect(kept(a).isSuperset(of: ["precious", "b1", "b2"]))
    }

    @Test func aLinkedConfigStaysALinkAndADeletedOneIsBackedUp() throws {
        let sync = tempDir()
        let a = try mac("A", sync), b = try mac("B", sync)
        let real = tempDir().appendingPathComponent("config.ts")
        try "mine".write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: a.settings.configFile, withDestinationURL: real)
        try a.pull(); try b.pull()
        try write("from b", b); try b.pull(); try a.pull()
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: a.settings.configFile.path)) != nil)
        #expect(try String(contentsOf: real, encoding: .utf8) == "from b")
        let beside = try FileManager.default.contentsOfDirectory(atPath: real.deletingLastPathComponent().path)
        #expect(beside.contains { $0.hasSuffix(".bak") }) // beside the real file
        try FileManager.default.removeItem(at: b.settings.configFile)
        try b.pull(); let r = try a.pull()
        #expect(config(a) == nil)
        #expect(try String(contentsOf: #require(r.configReplaced), encoding: .utf8) == "from b")
    }
}
