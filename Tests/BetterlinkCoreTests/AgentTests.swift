import Foundation
import Testing
@testable import BetterlinkCore

private let brave = Browser.brave
private let chrome = Browser.known(bundleId: "com.google.Chrome")!
private let safari = Browser.known(bundleId: "com.apple.Safari")!

private func tempFolder() throws -> SettingsFolder {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("bl-agent-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return SettingsFolder(directory: d)
}

private func env(_ folder: SettingsFolder) -> AgentEnvironment {
    AgentEnvironment(folder: folder, installed: [brave, chrome, safari])
}

/// Runs a command and returns the decoded response envelope.
private func call(_ command: String, _ input: [String: Any] = [:], in folder: SettingsFolder) -> [String: Any] {
    let out = Agent.run(command, input: input, env: env(folder)).json()
    return (try? JSONSerialization.jsonObject(with: out) as? [String: Any]) ?? [:]
}

private func data(_ r: [String: Any]) -> Any? { r["data"] }

@Suite(.serialized) struct RuleStoreLockTests {
    /// Two processes (the app and an agent) can write at once; none of the
    /// writes may be lost.
    @Test func concurrentUpdatesAreAllKept() throws {
        let folder = try tempFolder()
        let store = RuleStore(folder: folder)
        try store.save(RuleStore.Contents())
        DispatchQueue.concurrentPerform(iterations: 40) { i in
            _ = try? store.update { $0.rules.append(Rule(kind: .domain, pattern: "s\(i).example.com", profile: "Default")) }
        }
        #expect(try store.load().rules.count == 40)
    }

    @Test func fallbackAndLogSettingLiveInRulesJSON() throws {
        let folder = try tempFolder()
        let store = RuleStore(folder: folder)
        try store.update {
            $0.fallback = ProfileRef(browser: "com.google.Chrome", directory: "Profile 1")
            $0.showLog = true
        }
        let c = try store.load()
        #expect(c.fallback == ProfileRef(browser: "com.google.Chrome", directory: "Profile 1"))
        #expect(c.showLog == true)
        // A 0.1 file without them still loads.
        try #"{"version":1,"rules":[]}"#.write(to: folder.rulesFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: folder.rulesFile.path)
        #expect(try store.load().fallback == nil)
    }
}

@Suite(.serialized) struct AgentTests {
    func seeded() throws -> SettingsFolder {
        let folder = try tempFolder()
        try RuleStore(folder: folder).save(RuleStore.Contents(rules: [], profiles: [
            BrowserProfile(browser: brave.bundleId, directory: "Default", name: "Personal", color: 0xBCC6F3),
            BrowserProfile(browser: brave.bundleId, directory: "Profile 1", name: "Work", color: 0xF0735A),
            BrowserProfile(browser: chrome.bundleId, directory: "Profile 2", name: "Client", color: nil),
        ]))
        return folder
    }

    @Test func everyResponseIsAVersionedEnvelope() throws {
        let r = call("rules.list", in: try seeded())
        #expect(r["version"] as? Int == 1)
        #expect(r["ok"] as? Bool == true)
        #expect((data(r) as? [Any])?.isEmpty == true)
        let bad = call("no.such.command", in: try seeded())
        #expect(bad["ok"] as? Bool == false)
        #expect((bad["error"] as? String)?.contains("no.such.command") == true)
    }

    @Test func addListMoveUpdateRemoveRules() throws {
        let f = try seeded()
        let a = call("rules.add", ["kind": "domain", "pattern": "example.com", "profile": "Work"], in: f)
        #expect(a["ok"] as? Bool == true, "\(a)")
        let b = call("rules.add", ["kind": "startsWith", "pattern": "https://app.client.io", "browser": "Google Chrome", "profile": "Client"], in: f)
        #expect(b["ok"] as? Bool == true, "\(b)")
        var list = data(call("rules.list", in: f)) as? [[String: Any]] ?? []
        #expect(list.map { $0["pattern"] as? String } == ["example.com", "https://app.client.io"])
        #expect(list[0]["browser"] as? String == "com.brave.Browser")
        #expect(list[0]["profileName"] as? String == "Work")
        let secondID = list[1]["id"] as! String

        #expect(call("rules.move", ["id": secondID, "to": 1], in: f)["ok"] as? Bool == true)
        list = data(call("rules.list", in: f)) as? [[String: Any]] ?? []
        #expect(list.first?["id"] as? String == secondID)

        #expect(call("rules.update", ["id": secondID, "pattern": "https://portal.client.io"], in: f)["ok"] as? Bool == true)
        #expect(call("rules.remove", ["id": secondID], in: f)["ok"] as? Bool == true)
        list = data(call("rules.list", in: f)) as? [[String: Any]] ?? []
        #expect(list.map { $0["pattern"] as? String } == ["example.com"])
    }

    @Test(arguments: [
        (["kind": "domain", "pattern": "ex ample.org", "profile": "Work"], "domain"),
        (["kind": "regex", "pattern": "x", "profile": "Work"], "kind"),
        (["kind": "domain", "pattern": "example.com", "profile": "Nope"], "profile"),
        (["kind": "domain", "pattern": "example.com"], "profile"),
    ] as [([String: String], String)])
    func invalidRulesAreRefusedWithAReason(input: [String: String], mentions: String) throws {
        let f = try seeded()
        let r = call("rules.add", input, in: f)
        #expect(r["ok"] as? Bool == false)
        #expect((r["error"] as? String)?.lowercased().contains(mentions) == true, "\(r)")
        #expect((data(call("rules.list", in: f)) as? [Any])?.isEmpty == true)
    }

    @Test func fallbackGetAndSet() throws {
        let f = try seeded()
        #expect(call("fallback.set", ["browser": "Brave", "profile": "Personal"], in: f)["ok"] as? Bool == true)
        let g = data(call("fallback.get", in: f)) as? [String: Any]
        #expect(g?["directory"] as? String == "Default")
        #expect(g?["name"] as? String == "Personal")
        #expect(call("fallback.set", ["browser": "Safari", "profile": "Safari"], in: f)["ok"] as? Bool == true)
        #expect(call("fallback.set", ["profile": "Missing"], in: f)["ok"] as? Bool == false)
    }

    @Test func profilesAddUpdateRemoveAndValidate() throws {
        let f = try seeded()
        #expect(call("profiles.add", ["browser": "Google Chrome", "directory": "Profile 3", "name": "Side project", "color": "#5B8DEF"], in: f)["ok"] as? Bool == true)
        #expect(call("profiles.add", ["browser": "Google Chrome", "directory": "Profile 3 --x", "name": "Bad"], in: f)["ok"] as? Bool == false)
        #expect(call("profiles.add", ["browser": "Google Chrome", "directory": "Profile 4", "name": "Client"], in: f)["ok"] as? Bool == false)
        #expect(call("profiles.update", ["browser": "Google Chrome", "directory": "Profile 3", "name": "Hobby"], in: f)["ok"] as? Bool == true)
        let list = data(call("profiles.list", in: f)) as? [[String: Any]] ?? []
        #expect(list.contains { $0["name"] as? String == "Hobby" && $0["color"] as? String == "#5B8DEF" })
        #expect(list.contains { $0["browser"] as? String == "com.apple.Safari" })   // installed plain browsers listed
        #expect(call("profiles.remove", ["browser": "Google Chrome", "directory": "Profile 3"], in: f)["ok"] as? Bool == true)
        #expect(!(data(call("profiles.list", in: f)) as? [[String: Any]] ?? []).contains { $0["name"] as? String == "Hobby" })
    }

    @Test func removingAProfileARuleUsesIsRefused() throws {
        let f = try seeded()
        _ = call("rules.add", ["kind": "domain", "pattern": "example.com", "profile": "Work"], in: f)
        let r = call("profiles.remove", ["browser": "Brave", "directory": "Profile 1"], in: f)
        #expect(r["ok"] as? Bool == false)
        #expect((r["error"] as? String)?.contains("rule") == true)
    }

    @Test func testShowsWhereALinkOpens() throws {
        let f = try seeded()
        _ = call("rules.add", ["kind": "domain", "pattern": "example.com", "profile": "Work"], in: f)
        _ = call("fallback.set", ["browser": "Brave", "profile": "Personal"], in: f)
        let hit = data(call("test", ["link": "https://app.example.com/x"], in: f)) as? [String: Any]
        #expect(hit?["profileName"] as? String == "Work")
        let miss = data(call("test", ["link": "https://evil.com\\@example.com/"], in: f)) as? [String: Any]
        #expect(miss?["profileName"] as? String == "Personal")
        #expect(miss?["link"] as? String == "https://evil.com/@example.com/")
    }

    @Test func settingsShowLogAndFolder() throws {
        let f = try seeded()
        #expect(call("settings.set", ["showLog": true], in: f)["ok"] as? Bool == true)
        let s = data(call("settings.get", in: f)) as? [String: Any]
        #expect(s?["showLog"] as? Bool == true)
        #expect(s?["settingsFolder"] as? String == f.directory.path)
    }

    @Test func browsersListsWhatIsInstalled() throws {
        let b = data(call("browsers.list", in: try seeded())) as? [[String: Any]] ?? []
        #expect(b.map { $0["name"] as? String } == ["Brave", "Google Chrome", "Safari"])
        #expect(b.first?["family"] as? String == "chromium")
    }

    @Test func configInitCreatesTheStarterOnce() throws {
        let f = try seeded()
        #expect(call("config.init", in: f)["ok"] as? Bool == true)
        #expect(FileManager.default.fileExists(atPath: f.configFile.path))
        #expect(call("config.init", in: f)["ok"] as? Bool == false)   // never overwrites
    }

    @Test func aDamagedRulesFileIsReportedNotReplaced() throws {
        let f = try seeded()
        try "{nope".write(to: f.rulesFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.rulesFile.path)
        let r = call("rules.add", ["kind": "domain", "pattern": "example.com", "profile": "Work"], in: f)
        #expect(r["ok"] as? Bool == false)
        #expect(try String(contentsOf: f.rulesFile, encoding: .utf8) == "{nope")
    }
}

/// PR #7 review fixes.
@Suite(.serialized) struct AgentReviewTests {
    func folder() throws -> SettingsFolder {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bl-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = SettingsFolder(directory: d)
        try RuleStore(folder: f).save(RuleStore.Contents(profiles: [
            BrowserProfile(browser: "com.brave.Browser", directory: "Profile 1", name: "Work", color: nil),
        ]))
        return f
    }

    func call(_ c: String, _ input: [String: Any], _ f: SettingsFolder) -> [String: Any] {
        let env = AgentEnvironment(folder: f, installed: [Browser.brave, Browser.known(bundleId: "com.apple.Safari")!])
        return (try? JSONSerialization.jsonObject(with: Agent.run(c, input: input, env: env).json()) as? [String: Any]) ?? [:]
    }

    /// F4: wrong JSON types are refused, never coerced.
    @Test func wrongTypesAreRefused() throws {
        let f = try folder()
        #expect(call("rules.add", ["kind": "domain", "pattern": "example.com", "profile": "Work", "position": 1.5], f)["ok"] as? Bool == false)
        #expect(call("rules.add", ["kind": "domain", "pattern": "example.com", "profile": "Work", "position": "1"], f)["ok"] as? Bool == false)
        #expect(call("settings.set", ["showLog": 1], f)["ok"] as? Bool == false)
        #expect(call("profiles.update", ["browser": "Brave", "directory": "Profile 1", "color": 5], f)["ok"] as? Bool == false)
        #expect(call("rules.add", ["kind": "domain", "pattern": 7, "profile": "Work"], f)["ok"] as? Bool == false)
    }

    /// F5: a fallback naming a browser this Mac doesn't have (a synced
    /// settings folder) opens links in the default instead of failing.
    @Test func aFallbackForAMissingBrowserUsesTheDefault() {
        let chromeOnly = [Browser.known(bundleId: "com.google.Chrome")!]
        let stored = ProfileRef(browser: "com.brave.Browser", directory: "Profile 1")
        #expect(Agent.effectiveFallback(stored, installed: chromeOnly) == ProfileRef(browser: "com.google.Chrome", directory: "Default"))
        #expect(Agent.effectiveFallback(stored, installed: [Browser.brave]) == stored)
        #expect(Agent.effectiveFallback(nil, installed: [Browser.brave]) == ProfileRef(browser: "com.brave.Browser", directory: "Default"))
    }

    /// Follow-up a805: "the first Chromium browser it has installed" means
    /// Browser.known's order, which the README spells out. Keep them in step.
    @Test func defaultFallbackFollowsTheReadmeOrder() {
        let chromium = Browser.known.filter { $0.family == .chromium }.map(\.name)
        #expect(Array(chromium.prefix(9)) == ["Brave", "Brave Nightly", "Google Chrome", "Google Chrome Beta",
                                              "Google Chrome Canary", "Chromium", "Microsoft Edge", "Dia", "Comet"])
        let installed = Browser.known.filter { ["Dia", "Google Chrome", "Safari"].contains($0.name) }
        #expect(Agent.defaultFallback(installed: installed) == ProfileRef(browser: "com.google.Chrome", directory: "Default"))
    }
}

/// PR #7 round 2.
@Suite(.serialized) struct AgentRound2Tests {
    func call(_ c: String, _ input: [String: Any], _ f: SettingsFolder, installed: [Browser] = [Browser.brave]) -> [String: Any] {
        let env = AgentEnvironment(folder: f, installed: installed)
        return (try? JSONSerialization.jsonObject(with: Agent.run(c, input: input, env: env).json()) as? [String: Any]) ?? [:]
    }
    func folder() throws -> SettingsFolder {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bl-r2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let f = SettingsFolder(directory: d)
        try RuleStore(folder: f).save(RuleStore.Contents(profiles: [
            BrowserProfile(browser: "com.brave.Browser", directory: "Profile 1", name: "Work", color: nil)]))
        return f
    }

    /// F4: a number too large for Int is refused, never wrapped.
    @Test func hugeNumbersAreRefused() throws {
        let f = try folder()
        let huge = try JSONSerialization.jsonObject(with: Data(#"{"kind":"domain","pattern":"example.com","profile":"Work","position":18446744073709551615}"#.utf8)) as! [String: Any]
        #expect(call("rules.add", huge, f)["ok"] as? Bool == false)
    }

    /// Round 3 F4: the smallest Int overflowed `position - 1` and crashed.
    @Test func positionsBelowOneAreRefused() throws {
        let f = try folder()
        // A real rule, so rules.move reaches the position check.
        let id = (call("rules.add", ["kind": "domain", "pattern": "example.com", "profile": "Work"], f)["data"] as? [String: Any])?["id"] as? String
        #expect(id != nil)
        for n in [Int.min, -1, 0] {
            #expect(call("rules.add", ["kind": "domain", "pattern": "example.org", "profile": "Work", "position": n], f)["ok"] as? Bool == false)
            #expect(call("rules.move", ["id": id ?? "", "to": n], f)["ok"] as? Bool == false)
        }
    }

    /// Note: fallback.get says when the stored fallback was replaced on this Mac.
    @Test func fallbackGetSaysWhenReplaced() throws {
        let f = try folder()
        try RuleStore(folder: f).update { $0.fallback = ProfileRef(browser: "com.google.Chrome", directory: "Profile 9") }
        let d = call("fallback.get", [:], f)["data"] as? [String: Any]
        #expect(d?["replaced"] as? Bool == true)
        #expect((d?["stored"] as? [String: Any])?["browser"] as? String == "com.google.Chrome")
    }

    /// Note: profiles.import fails when it can read no browser.
    @Test func importThatReadsNothingFails() throws {
        let f = try folder()
        let r = call("profiles.import", [:], f, installed: [Browser.known(bundleId: "com.apple.Safari")!])
        #expect(r["ok"] as? Bool == false)
    }
}

@Suite(.serialized) struct AgentKeysTests {
    @Test func addListTestUpdateRemoveModifierKeys() throws {
        let f = try AgentTests().seeded()
        #expect(call("fallback.set", ["browser": "Brave", "profile": "Personal"], in: f)["ok"] as? Bool == true)
        let a = call("keys.add", ["keys": "ctrl+cmd", "profile": "Work"], in: f)
        #expect(a["ok"] as? Bool == true, "\(a)")
        let b = call("keys.add", ["keys": ["option"], "browser": "Google Chrome", "profile": "Client"], in: f)
        #expect(b["ok"] as? Bool == true, "\(b)")
        var list = data(call("keys.list", in: f)) as? [[String: Any]] ?? []
        #expect(list.map { $0["symbols"] as? String } == ["⌃⌘", "⌥"])
        #expect(list[0]["keys"] as? [String] == ["control", "command"])
        #expect(list[0]["profileName"] as? String == "Work")

        func opens(_ keys: Any?) -> String? {
            var input: [String: Any] = ["link": "https://example.com/"]
            if let keys { input["keys"] = keys }
            return (data(call("test", input, in: f)) as? [String: Any])?["profileName"] as? String
        }
        #expect(opens("control,command") == "Work")
        #expect(opens("⌃⌘") == "Work")
        #expect(opens(["option"]) == "Client")
        #expect(opens(nil) == "Personal")
        #expect(opens("shift") == "Personal")
        #expect(call("test", ["link": "https://example.com/", "keys": "hyper"], in: f)["ok"] as? Bool == false)

        // Refused: the same keys again, no keys, a key that isn't one.
        #expect(call("keys.add", ["keys": "command,control", "profile": "Personal"], in: f)["ok"] as? Bool == false)
        #expect(call("keys.add", ["keys": "", "profile": "Personal"], in: f)["ok"] as? Bool == false)
        #expect(call("keys.add", ["keys": 3, "profile": "Personal"], in: f)["ok"] as? Bool == false)
        #expect(call("keys.update", ["id": list[1]["id"] as! String, "keys": "control,command"], in: f)["ok"] as? Bool == false)

        // A profile a key rule uses can't be removed.
        let rm = call("profiles.remove", ["browser": "Brave", "directory": "Profile 1"], in: f)
        #expect(rm["ok"] as? Bool == false)
        #expect((rm["error"] as? String)?.contains("⌃⌘") == true)

        let id = list[0]["id"] as! String
        #expect(call("keys.update", ["id": id, "keys": "shift,command", "profile": "Personal"], in: f)["ok"] as? Bool == true)
        #expect(opens("shift,command") == "Personal")
        #expect(call("keys.remove", ["id": id], in: f)["ok"] as? Bool == true)
        list = data(call("keys.list", in: f)) as? [[String: Any]] ?? []
        #expect(list.count == 1)
        #expect((data(call("status", in: f)) as? [String: Any])?["keyRules"] as? Int == 1)
    }
}
