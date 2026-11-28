import Foundation
import Testing
@testable import BetterlinkCore

// A Link Rule with more than one profile, in order: each Mac opens the link
// in the first one it has (README, Link Rules; docs/sync.md).

private let diaID = "company.thebrowser.dia"
private let braveID = Browser.brave.bundleId
private let dia = ProfileRef(browser: diaID, directory: "Default")
private let brave = ProfileRef(browser: braveID, directory: "Default")
private let braveWork = ProfileRef(browser: braveID, directory: "Profile 1")
private let both = ProfileCatalog(profiles: [
    BrowserProfile(browser: diaID, directory: "Default", name: "Primary", color: nil),
    BrowserProfile(browser: braveID, directory: "Default", name: "Primary", color: nil),
    BrowserProfile(browser: braveID, directory: "Profile 1", name: "Work", color: nil),
])
private let fallbackRef = braveWork

private func rule(_ targets: [ProfileRef]) -> Rule { rule("acme.com", targets) }

private func rule(_ pattern: String, _ targets: [ProfileRef]) -> Rule {
    var r = Rule(kind: .domain, pattern: pattern, browser: targets[0].browser, profile: targets[0].directory)
    r.setTargets(targets)
    return r
}

private func routes(_ rules: [Rule], installed: Set<String>?, script: (any LinkScript)? = nil) -> Router {
    Router(rules: rules, script: script, catalog: both, fallback: fallbackRef, installed: installed)
}

private func opened(_ d: Decision) -> ProfileRef? {
    if case .open(let p, _) = d.action { return p.ref }
    return nil
}

private struct Verdict: LinkScript {
    let v: ScriptVerdict
    func route(_ link: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict { v }
}

@Suite struct RuleBackupsTests {
    // MARK: Stored

    @Test func aRuleFromBeforeBackupsReadsAndWritesAsItDid() throws {
        let old = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","kind":"domain","pattern":"acme.com","browser":"com.brave.Browser","profile":"Default"}"#
        let r = try JSONDecoder().decode(Rule.self, from: Data(old.utf8))
        #expect(r.backups.isEmpty && r.targets == [brave])
        let back = String(decoding: try JSONEncoder().encode(r), as: UTF8.self)
        #expect(!back.contains("backups"), "no field for a rule without backups")
        let multi = rule([dia, brave])
        let again = try JSONDecoder().decode(Rule.self, from: try JSONEncoder().encode(multi))
        #expect(again == multi && again.targets == [dia, brave])
    }

    @Test func aProfileNamedTwiceKeepsItsFirstPlace() {
        var r = rule([dia])
        r.setTargets([dia, brave, dia, braveWork, brave])
        #expect(r.targets == [dia, brave, braveWork])
        r.setTargets([])
        #expect(r.targets == [dia, brave, braveWork], "an empty list changes nothing")
    }

    // MARK: Routing

    @Test func eachMacOpensTheFirstProfileItHas() {
        let rules = [rule([dia, brave])]
        // The personal laptop has Dia.
        let personal = routes(rules, installed: [diaID, braveID]).decide("https://acme.com/x")
        #expect(opened(personal) == dia)
        #expect(personal.chosenBy == Decision.Chooser.rule(1))
        #expect(personal.reason == "Rule 1 (domains matching acme.com) chose Primary.")
        // The work laptop has only Brave, though the catalog still lists Dia's profiles.
        let work = routes(rules, installed: [braveID]).decide("https://acme.com/x")
        #expect(opened(work) == brave)
        #expect(work.chosenBy == Decision.Chooser.rule(1))
        #expect(work.reason == "Rule 1 (domains matching acme.com) chose Primary, the first of its profiles this Mac has.")
        // A Mac with neither opens the fallback.
        let neither = routes(rules, installed: ["com.google.Chrome"]).decide("https://acme.com/x")
        #expect(opened(neither) == fallbackRef)
        #expect(neither.reason == "Rule 1 names no profile this Mac has: opens in Work.")
        #expect(neither.chosenBy == nil)
    }

    @Test func aProfileSyncCouldNotFindIsPassedOver() {
        // Dia is installed but has no such profile: sync keeps it with no folder.
        let r = routes([rule([ProfileRef(browser: diaID, directory: ""), brave])], installed: [diaID, braveID])
        #expect(opened(r.decide("https://acme.com")) == brave)
    }

    @Test func withoutAnInstalledListTheCatalogDecides() {
        let r = routes([rule([ProfileRef(browser: diaID, directory: "Profile 9"), brave])], installed: nil)
        #expect(opened(r.decide("https://acme.com")) == brave)
        // A single-profile rule says what it always said.
        let one = routes([rule([ProfileRef(browser: diaID, directory: "Profile 9")])], installed: nil)
        #expect(one.decide("https://acme.com").reason == "Rule 1 names a missing profile: opens in Work.")
    }

    @Test func configTsCanReturnAListToo() {
        let list = ScriptVerdict.firstOf([ScriptTarget("Primary", browser: "Dia"), ScriptTarget("Primary", browser: "Brave")])
        let personal = routes([], installed: [diaID, braveID], script: Verdict(v: list)).decide("https://acme.com")
        #expect(opened(personal) == dia)
        #expect(personal.chosenBy == Decision.Chooser.script)
        let work = routes([], installed: [braveID], script: Verdict(v: list)).decide("https://acme.com")
        #expect(opened(work) == brave)
        let none = routes([], installed: [braveID], script: Verdict(v: .firstOf([ScriptTarget("Primary", browser: "Dia")])))
            .decide("https://acme.com")
        #expect(opened(none) == fallbackRef)
        #expect(none.reason == "config.ts chose profiles this Mac doesn't have (Dia Primary): opens in Work.")
        #expect(none.chosenBy == nil)
    }

    // MARK: The Link Rules page

    @Test func aRuleIsListedUnderTheProfileItUsesHere() {
        let rules = [rule("a.com", [dia, brave]), rule("b.com", [brave]), rule("c.com", [dia])]
        let workLaptop = RuleGroups.opensIn { $0.browser == braveID }
        let groups = RuleGroups.groups(rules, order: [dia, brave], key: workLaptop)
        #expect(groups.map(\.target) == [dia, brave])
        #expect(groups.map(\.positions) == [[2], [0, 1]], "a.com is Brave's here; c.com has no profile here, so it stays Dia's")
        // Both a.com and b.com open in Brave here, so they don't cross.
        #expect(RuleGroups.crossings([rule("acme.com", [dia, brave]), rule("app.acme.com", [brave])], key: workLaptop).isEmpty)
        #expect(RuleGroups.crossings([rule("acme.com", [dia, brave]), rule("app.acme.com", [brave])]).count == 1,
                "by first choice they are two profiles")
        // Editing Brave's rules here keeps Dia's rule in its place.
        var edited = [rules[0], rules[1]]
        edited[0].pattern = "a2.com"
        let spliced = RuleGroups.splice(rules, profile: brave, edited: edited.reversed(), key: workLaptop)
        #expect(spliced.map(\.pattern) == ["b.com", "a2.com", "c.com"])
    }

    // MARK: Sync

    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("bl-backups-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func mac(_ name: String, sync: URL, resolve: @escaping (String, String, ProfileIdentity) -> String?) throws -> SyncSession {
        let s = SettingsFolder(directory: tempDir())
        _ = try RuleStore(folder: s).update { _ in }
        return SyncSession(settings: s, folder: SyncFolder(sync), device: name, name: "Mac \(name)",
                           selection: SyncSelection(global: true),
                           identity: { ProfileIdentity(name: "Primary", account: $0.browser == diaID ? "me@home" : "me@work") },
                           resolve: resolve)
    }

    func t(_ s: Double) -> Date { Date(timeIntervalSince1970: 1_800_000_000 + s) }

    /// The personal laptop has Dia, the work laptop Brave. Each adds its own
    /// profile to one rule, and the rule works on both.
    @Test func oneRuleSyncsAndWorksOnBothMacs() throws {
        let sync = tempDir()
        // Personal: Dia installed; Brave not, so a Brave profile stays as it is.
        let personal = try mac("P", sync: sync) { b, d, _ in d }
        // Work: Dia installed too but without this profile (the harder case), Brave has it.
        let work = try mac("W", sync: sync) { b, d, _ in b == diaID ? nil : d }
        _ = try RuleStore(folder: personal.settings).update { $0.rules = [rule([dia])] }
        try personal.pull(now: t(1))
        try work.pull(now: t(2))
        let id = try RuleStore(folder: personal.settings).load().rules[0].id

        // Work adds Brave Primary after Dia Primary.
        _ = try RuleStore(folder: work.settings).update { $0.rules[0].backups = [brave] }
        try work.pull(now: t(3))
        // Work keeps Dia with no folder (never opens), then Brave.
        #expect(try RuleStore(folder: work.settings).load().rules[0].targets == [ProfileRef(browser: diaID, directory: ""), brave])
        #expect(work.localNotes.load().unresolvedRules == nil, "Brave is here, so the rule isn't unresolved")
        try personal.pull(now: t(4))
        let p = try RuleStore(folder: personal.settings).load().rules
        #expect(p.map(\.id) == [id] && p[0].targets == [dia, brave])

        // Nothing moves after another round, and Work never wrote its empty Dia folder over Personal's.
        try work.pull(now: t(5)); try personal.pull(now: t(6))
        #expect(try RuleStore(folder: personal.settings).load().rules[0].targets == [dia, brave])
        #expect(personal.state.value(SyncModel.ruleID(id), "profile") == .string("Default"))
        #expect(personal.state.value(SyncModel.ruleID(id), "profileAccount") == .string("me@home"))
        let synced = SyncModel.syncedBackups(personal.state.value(SyncModel.ruleID(id), "backups"))
        #expect(synced == [SyncModel.SyncedTarget(browser: braveID, profile: "Default", profileName: "Primary", profileAccount: "me@work")])

        // Each opens the link where it should.
        let pr = routes(try RuleStore(folder: personal.settings).load().rules, installed: [diaID])
        #expect(opened(pr.decide("https://acme.com")) == dia)
        let wr = routes(try RuleStore(folder: work.settings).load().rules, installed: [diaID, braveID])
        #expect(opened(wr.decide("https://acme.com")) == brave)

        // Removing the backup on Personal removes it on Work.
        _ = try RuleStore(folder: personal.settings).update { $0.rules[0].backups = [] }
        try personal.pull(now: t(7)); try work.pull(now: t(8))
        #expect(try RuleStore(folder: work.settings).load().rules[0].backups.isEmpty)
        #expect(personal.state.value(SyncModel.ruleID(id), "backups") == .null)
    }

    @Test func aRuleWithNoProfileHereIsMarked() throws {
        let sync = tempDir()
        let a = try mac("A", sync: sync) { _, d, _ in d }
        let b = try mac("B", sync: sync) { _, _, _ in nil }
        _ = try RuleStore(folder: a.settings).update { $0.rules = [rule([dia, brave])] }
        try a.pull(now: t(1)); try b.pull(now: t(2))
        let id = try RuleStore(folder: a.settings).load().rules[0].id
        #expect(b.localNotes.load().unresolvedRules == [id])
        #expect(b.localNotes.load().missingProfiles == [id.uuidString: "Primary"])
    }

    @Test func aMovedPlaceholderStillSendsWhatAnotherMacKnows() {
        // A backup this Mac couldn't find, moved to another place in the list.
        let id = "rule:X"
        let missing = ProfileRef(browser: diaID, directory: "")
        let entry = SyncModel.SyncedTarget(browser: diaID, profile: "Profile 3", profileName: "Home", profileAccount: "me@home")
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        var state = SyncState()
        state.entities[id] = ["backups": Stamped(.string(String(decoding: try! enc.encode([entry]), as: UTF8.self)),
                                                 HLC(wall: 1, counter: 0, device: "A"))]
        let applied = [SyncModel.backupKey(id, 1): missing]
        let out = SyncModel.backupsField(id, [brave, missing], state: state, applied: applied,
                                         identity: { _ in ProfileIdentity(name: "Primary", account: nil) })
        #expect(SyncModel.syncedBackups(out) == [SyncModel.SyncedTarget(browser: braveID, profile: "Default", profileName: "Primary"), entry])
    }

    // MARK: CLI

    private func folder() throws -> SettingsFolder {
        let d = tempDir()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        let f = SettingsFolder(directory: d)
        try RuleStore(folder: f).save(RuleStore.Contents(profiles: both.profiles))
        return f
    }

    @Test func theCommandAddsListsAndClearsBackups() throws {
        let f = try folder()
        // The work laptop: Brave only, though Dia's profiles are still listed.
        let env = AgentEnvironment(folder: f, installed: [Browser.brave])
        func run(_ c: String, _ i: [String: Any] = [:]) -> AgentResponse { Agent.run(c, input: i, env: env) }
        let added = run("rules.add", ["kind": "domain", "pattern": "acme.com", "profile": "Primary", "browser": "Dia",
                                      "then": ["Brave:Primary", "Work", "Brave: Primary"]])
        #expect(added.error == nil)
        #expect(try RuleStore(folder: f).load().rules[0].targets == [dia, brave, braveWork])
        let list = try #require(run("rules.list").data as? [[String: Any]])
        #expect((list[0]["backups"] as? [[String: Any]])?.map { $0["profile"] as? String } == ["Default", "Profile 1"])
        #expect((list[0]["opensIn"] as? [String: Any])?["browserName"] as? String == "Brave")
        #expect(list[0]["profile"] as? String == "Default" && list[0]["browserName"] as? String == "Dia", "the first choice stays first")
        // Listed under Brave Primary, where it opens here.
        let groups = try #require(run("rules.profiles").data as? [[String: Any]])
        #expect(groups.map { $0["browserName"] as? String } == ["Brave"])
        #expect(try #require(run("rules.list", ["profile": "Primary", "browser": "Brave"]).data as? [Any]).count == 1)
        // A profile a rule falls back to can't be removed.
        #expect(run("profiles.remove", ["browser": "Brave", "directory": "Profile 1"]).error?.contains("rule 1") == true)
        // Changing the first choice to a backup keeps one of each.
        let id = list[0]["id"] as! String
        #expect(run("rules.update", ["id": id, "profile": "Work", "browser": "Brave"]).error == nil)
        #expect(try RuleStore(folder: f).load().rules[0].targets == [braveWork, brave])
        #expect(run("rules.update", ["id": id, "then": []]).error == nil)
        #expect(try RuleStore(folder: f).load().rules[0].backups.isEmpty)
        #expect(run("rules.update", ["id": id, "then": ["Nobody"]]).error?.contains("No profile \"Nobody\"") == true)
        #expect(run("rules.update", ["id": id, "then": "Work"]).error == "then must be a list of profiles.")
    }
}
