import Foundation
import Testing
@testable import BetterlinkCore

@Suite struct ModifierKeysTests {
    @Test func namesAndSymbolsFollowApplesOrder() {
        let k: ModifierKeys = [.command, .control]
        #expect(k.names == ["control", "command"])
        #expect(k.symbols == "⌃⌘")
        #expect(k.spoken == "Control-Command")
        #expect(ModifierKeys([.command, .shift, .option, .control]).symbols == "⌃⌥⇧⌘")
        #expect(ModifierKeys().symbols == "")
    }

    @Test func readsNamesAliasesAndSymbols() {
        #expect(ModifierKeys(names: ["control", "command"]) == [.control, .command])
        #expect(ModifierKeys(names: ["Ctrl", " CMD ", "alt", "opt", "shift"]) == [.control, .command, .option, .shift])
        #expect(ModifierKeys(names: ["⌃", "⌘"]) == [.control, .command])
        #expect(ModifierKeys(names: []) == [])
        // A typo is refused, never quietly a different combination.
        #expect(ModifierKeys(names: ["control", "hyper"]) == nil)
        #expect(ModifierKeys(names: ["fn"]) == nil)
    }

    @Test func storedAsNamesInRulesJSON() throws {
        let rule = ModifierRule(keys: [.command, .control], profile: "Profile 1")
        let json = String(decoding: try JSONEncoder().encode(rule), as: UTF8.self)
        #expect(json.contains(#""keys":["control","command"]"#))
        #expect(try JSONDecoder().decode(ModifierRule.self, from: Data(json.utf8)) == rule)
        let bad = json.replacingOccurrences(of: #""control""#, with: #""hyper""#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ModifierRule.self, from: Data(bad.utf8)) }
    }
}

@Suite struct ModifierRuleTests {
    let rule = ModifierRule(keys: [.control, .command], profile: "Profile 1")

    /// Exactly the keys: more, fewer or none don't match.
    @Test(arguments: [
        (ModifierKeys([.control, .command]), true),
        (ModifierKeys([.command, .control]), true),
        (ModifierKeys([.control, .option, .command]), false),
        (ModifierKeys([.command]), false),
        (ModifierKeys([.control]), false),
        (ModifierKeys(), false),
    ])
    func matchesExactlyItsKeys(held: ModifierKeys, match: Bool) {
        #expect(rule.matches(held) == match)
    }

    @Test func aRuleWithNoKeysIsAProblemAndNeverMatches() {
        let empty = ModifierRule(keys: [], profile: "Profile 1")
        #expect(empty.problem != nil)
        #expect(!empty.matches([]))
    }

    @Test func theSameKeysTwiceIsAProblemOnTheSecond() {
        let list = [rule, ModifierRule(keys: [.option], profile: "Default"), ModifierRule(keys: [.command, .control], profile: "Default")]
        let problems = ModifierRule.problems(in: list)
        #expect(problems.keys.sorted() == [2])
        #expect(problems[2]?.contains("rule 1") == true)
        #expect(ModifierRule.problems(in: [rule, ModifierRule(keys: [], profile: "Default")])[1] == "Choose at least one key.")
    }
}

private struct FixedVerdict: LinkScript {
    let verdict: ScriptVerdict
    func route(_ link: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict { verdict }
}

/// Remembers the keys config.ts was given.
private final class KeysSeen: LinkScript, @unchecked Sendable {
    var keys: ModifierKeys?
    func route(_ link: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict { keys = modifiers; return .noOpinion }
}

@Suite struct ModifierRoutingTests {
    let keyRules = [ModifierRule(keys: [.control, .command], profile: "Profile 1")]
    let rules = [Rule(kind: .domain, pattern: "acme.com", profile: "Default")]

    func router(script: (any LinkScript)? = nil, keyRules: [ModifierRule]? = nil) -> Router {
        Router(rules: rules, modifierRules: keyRules ?? self.keyRules, script: script, catalog: catalog,
               fallback: ProfileRef(stored: "Default"))
    }

    @Test func heldKeysChooseTheirProfile() {
        let d = router().decide("https://example.com/x", modifiers: [.control, .command])
        #expect(d.action == .open(profile: work, argument: "https://example.com/x"))
        #expect(d.reason == "Holding ⌃⌘ chose Work.")
    }

    @Test func heldKeysWinOverLinkRulesAndConfig() {
        #expect(profile(of: router().decide("https://acme.com/", modifiers: [.control, .command])) == "Profile 1")
        let r = router(script: FixedVerdict(verdict: .profile("Primary")))
        #expect(profile(of: r.decide("https://acme.com/", modifiers: [.control, .command])) == "Profile 1")
        #expect(profile(of: r.decide("https://acme.com/")) == "Default")
    }

    @Test func otherKeysOrNoneRouteAsUsual() {
        let r = router(keyRules: keyRules + [ModifierRule(keys: [.option], profile: "Profile 1")])
        #expect(profile(of: r.decide("https://example.com/")) == "Default")
        #expect(profile(of: r.decide("https://example.com/", modifiers: [.command])) == "Default")
        #expect(profile(of: r.decide("https://example.com/", modifiers: [.control, .shift, .command])) == "Default")
        #expect(profile(of: r.decide("https://example.com/", modifiers: [.option])) == "Profile 1")
    }

    @Test func configSeesTheKeysWhenNoKeyRuleMatches() {
        let seen = KeysSeen()
        _ = router(script: seen).decide("https://example.com/", modifiers: [.shift])
        #expect(seen.keys == [.shift])
    }

    /// Held keys don't depend on the host, so an unclear host and a local
    /// file open in the chosen profile too.
    @Test func heldKeysApplyToUnclearHostsAndFiles() {
        let unclear = "https://evil.com\\@acme.com/"
        #expect(profile(of: router().decide(unclear)) == "Default")
        #expect(profile(of: router().decide(unclear, modifiers: [.control, .command])) == "Profile 1")
        #expect(profile(of: router().decide("file:///tmp/a.html", modifiers: [.control, .command])) == "Profile 1")
    }

    @Test func refusedLinksStayRefused() {
        #expect(router().decide("javascript:alert(1)", modifiers: [.control, .command]).action == .refuse)
    }

    @Test func aMissingProfileOpensInTheFallback() {
        let r = router(keyRules: [ModifierRule(keys: [.control, .command], profile: "Profile 9")])
        let d = r.decide("https://example.com/", modifiers: [.control, .command])
        #expect(profile(of: d) == "Default")
        #expect(d.reason.contains("missing profile"))
    }

    @Test func aRuleWithNoKeysNeverMatchesAPlainClick() {
        let r = router(keyRules: [ModifierRule(keys: [], profile: "Profile 1")])
        #expect(profile(of: r.decide("https://example.com/")) == "Default")
    }

    @Test func theFirstOfTwoSameKeyRulesWins() {
        let r = router(keyRules: [ModifierRule(keys: [.option], profile: "Profile 1"), ModifierRule(keys: [.option], profile: "Default")])
        #expect(profile(of: r.decide("https://example.com/", modifiers: [.option])) == "Profile 1")
    }
}

@Suite struct ModifierStoreTests {
    @Test func rulesJSONKeepsModifierRulesAndOldFilesStillLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bl-keys-\(UUID().uuidString)", isDirectory: true)
        let store = RuleStore(file: dir.appendingPathComponent("rules.json"))
        let keys = [ModifierRule(keys: [.control, .command], browser: "com.google.Chrome", profile: "Profile 1")]
        try store.update { $0.modifierRules = keys }
        // Other changes keep them.
        try store.update { $0.showLog = true }
        #expect(try store.load().modifierRules == keys)
        // A 0.2 file has none.
        try #"{"version":1,"rules":[]}"#.write(to: store.file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.file.path)
        #expect(try store.load().modifierRules == nil)
    }
}
