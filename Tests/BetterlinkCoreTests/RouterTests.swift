import Foundation
import Testing
@testable import BetterlinkCore

let primary = BrowserProfile(directory: "Default", name: "Primary", color: 0xBCC6F3)
let work = BrowserProfile(directory: "Profile 1", name: "Work", color: 0xFF00FF)
let catalog = ProfileCatalog(profiles: [primary, work])

func router(_ rules: [Rule], script: (any LinkScript)? = nil) -> Router {
    Router(rules: rules, script: script, catalog: catalog, fallback: ProfileRef(stored: "Default"))
}

func profile(of d: Decision) -> String? {
    if case .open(let p, _) = d.action { return p.directory }
    return nil
}

func web(_ s: String) -> Link {
    guard case .web(let l) = LinkParser.parse(s) else { fatalError("not web: \(s)") }
    return l
}

@Suite struct RuleTests {
    @Test(arguments: [
        ("https://acme.com/", true),
        ("https://app.acme.com/swap", true),
        ("https://a.b.acme.com", true),
        ("https://ACME.COM.", true),
        ("https://evil-acme.com/", false),
        ("https://acme.com.evil.com/", false),
        ("https://evil.com/?q=acme.com", false),
        ("https://evil.com\\@acme.com/", false),
        ("https://acme.com@evil.com/", false),
    ])
    func domainRule(url: String, match: Bool) {
        for pattern in ["acme.com", "*.acme.com", "ACME.com", "https://acme.com/anything"] {
            #expect(Rule(kind: .domain, pattern: pattern, profile: "Profile 1").matches(web(url)) == match, "\(pattern) vs \(url)")
        }
    }

    @Test(arguments: [
        ("https://app.acme.com/swap", true),
        ("https://app.acme.com/swap?x=1", true),
        ("http://app.acme.com/swap", false),     // pattern names https
        ("https://app.acme.com/pool", false),
        ("https://app.acme.com.evil.com/swap", false),
        ("https://evil.com/https://app.acme.com/swap", false),
        ("https://app.acme.com:8443/swap", false),
    ])
    func startsWithRule(url: String, match: Bool) {
        #expect(Rule(kind: .startsWith, pattern: "https://app.acme.com/swap", profile: "Profile 1").matches(web(url)) == match)
    }

    /// Follow-up from PR #1 review: a prefix ends at a path boundary.
    @Test(arguments: [
        ("https://app.acme.com/swap", true), ("https://app.acme.com/swap/x", true),
        ("https://app.acme.com/swap?x=1", true), ("https://app.acme.com/swap#top", true),
        ("https://app.acme.com/swapper", false),
    ])
    func startsWithStopsAtAPathBoundary(url: String, match: Bool) {
        #expect(Rule(kind: .startsWith, pattern: "https://app.acme.com/swap", profile: "Profile 1").matches(web(url)) == match)
        #expect(Rule(kind: .startsWith, pattern: "https://app.acme.com/", profile: "Profile 1").matches(web(url)))
    }

    /// PR #2 review F3: inside the query a prefix is a plain prefix.
    @Test func startsWithInsideTheQueryIsAPlainPrefix() {
        let r = Rule(kind: .startsWith, pattern: "https://acme.com/x?a", profile: "Profile 1")
        #expect(r.matches(web("https://acme.com/x?a=1")))
        #expect(r.matches(web("https://acme.com/x?ab")))
        #expect(!r.matches(web("https://acme.com/xy?a")))
    }

    @Test func startsWithWithoutSchemeMatchesBoth() {
        let r = Rule(kind: .startsWith, pattern: "app.acme.com", profile: "Profile 1")
        #expect(r.matches(web("http://app.acme.com/x")))
        #expect(r.matches(web("https://app.acme.com/")))
        #expect(!r.matches(web("https://acme.com/")))
    }

    /// Review F2: browsers load /billing/../admin as /admin, so a rule for
    /// /billing must not claim it.
    @Test(arguments: [
        "https://x.com/billing/../admin", "https://x.com/billing/%2e%2e/admin", "https://x.com/billing/.%2E/admin",
        "https://x.com/billing\\..\\admin",
    ])
    func startsWithSeesThePathTheBrowserLoads(url: String) {
        let r = Rule(kind: .startsWith, pattern: "https://x.com/billing", profile: "Profile 1")
        #expect(!r.matches(web(url)))
        #expect(web(url).path == "/admin")
    }

    /// Review F4: "contains" matches what browsers keep ("[]", "#" in a
    /// fragment) and non-ASCII text, encoded or not.
    @Test func containsMatchesEncodedAndUnencodedText() {
        #expect(Rule(kind: .contains, pattern: "tab[]=", profile: "Profile 1").matches(web("https://a.com/?tab[]=1")))
        #expect(Rule(kind: .contains, pattern: "café", profile: "Profile 1").matches(web("https://a.com/café")))
        #expect(Rule(kind: .contains, pattern: "café", profile: "Profile 1").matches(web("https://a.com/caf%C3%A9")))
        #expect(Rule(kind: .contains, pattern: "#/#room", profile: "Profile 1").matches(web("https://a.com/#/#room")))
        // One stray "%" doesn't stop the other escapes from decoding, and
        // case is folded after decoding.
        #expect(Rule(kind: .contains, pattern: "café", profile: "Profile 1").matches(web("https://x.com/café?d=100%")))
        #expect(Rule(kind: .contains, pattern: "café", profile: "Profile 1").matches(web("https://x.com/CAFÉ")))
        #expect(Rule(kind: .contains, pattern: "CAFÉ", profile: "Profile 1").matches(web("https://x.com/caf%C3%A9")))
        #expect(!Rule(kind: .contains, pattern: "café", profile: "Profile 1").matches(web("https://x.com/cafe")))
    }

    @Test func decodingEscapesKeepsWhatIsNotAnEscape() {
        #expect(Rule.decodingEscapes("a%20b%zz%2") == "a b%zz%2")
        #expect(Rule.decodingEscapes("100%") == "100%")
        #expect(Rule.decodingEscapes("caf%C3%A9%") == "café%")
    }

    @Test func containsRuleMatchesTheTextAnywhereInTheLink() {
        let r = Rule(kind: .contains, pattern: "Acme", profile: "Profile 1")
        #expect(r.matches(web("https://evil.com/?q=acme")))
        #expect(r.matches(web("https://app.acme.com/")))
        #expect(!r.matches(web("https://example.com/")))
    }

    @Test(arguments: [
        Rule(kind: .contains, pattern: "  ", profile: "Default"),
        Rule(kind: .domain, pattern: "", profile: "Default"),
        Rule(kind: .domain, pattern: "ex ample.org", profile: "Default"),
        Rule(kind: .domain, pattern: "[::1]", profile: "Default"),
        Rule(kind: .startsWith, pattern: "", profile: "Default"),
        Rule(kind: .startsWith, pattern: "javascript:alert(1)", profile: "Default"),
    ])
    func unusablePatternsReportAProblemAndNeverMatch(rule: Rule) {
        #expect(rule.problem != nil)
        #expect(!rule.matches(web("https://acme.com/")))
    }
}

private struct FixedScript: LinkScript {
    let verdict: ScriptVerdict
    func route(_ link: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict { verdict }
}

@Suite struct RouterTests {
    let rules = [Rule(kind: .domain, pattern: "acme.com", profile: "Profile 1")]

    @Test func matchingRuleChoosesItsProfile() {
        let d = router(rules).decide("https://app.acme.com/swap")
        #expect(profile(of: d) == "Profile 1")
        #expect(d.action == .open(profile: work, argument: "https://app.acme.com/swap"))
    }

    @Test(arguments: [
        "https://evil.com\\@acme.com/",
        "https://evil.com\\@app.acme.com/x",
        "https:evil.com/acme.com",
        "https://acmе.org/",
        "https://%E2%80%8Bacme.com/",
        "https://example.com/",
    ])
    func everythingElseGoesToTheFallback(url: String) {
        #expect(profile(of: router(rules).decide(url)) == "Default")
    }

    @Test func backslashLinkOpensTheHostTheRulesSaw() {
        let d = router(rules).decide("https://evil.com\\@acme.com/")
        #expect(d.action == .open(profile: primary, argument: "https://evil.com/@acme.com/"))
    }

    @Test func firstMatchingRuleWins() {
        let r = router([Rule(kind: .startsWith, pattern: "https://acme.com/blog", profile: "Default")] + rules)
        #expect(profile(of: r.decide("https://acme.com/blog/post")) == "Default")
        #expect(profile(of: r.decide("https://acme.com/")) == "Profile 1")
    }

    @Test func ruleForAMissingProfileFallsBack() {
        let d = router([Rule(kind: .domain, pattern: "acme.com", profile: "Profile 9")]).decide("https://acme.com")
        #expect(profile(of: d) == "Default")
    }

    @Test func scriptRunsFirst() {
        let d = router(rules, script: FixedScript(verdict: .profile("Primary"))).decide("https://acme.com")
        #expect(profile(of: d) == "Default")
        #expect(d.reason.contains("config.ts"))
    }

    @Test func scriptWithNoOpinionDefersToRules() {
        #expect(profile(of: router(rules, script: FixedScript(verdict: .noOpinion)).decide("https://acme.com")) == "Profile 1")
    }

    @Test func scriptErrorsAndUnknownProfilesFallBackEvenWhenARuleWouldMatch() {
        #expect(profile(of: router(rules, script: FixedScript(verdict: .error("boom"))).decide("https://acme.com")) == "Default")
        #expect(profile(of: router(rules, script: FixedScript(verdict: .profile("Workk"))).decide("https://acme.com")) == "Default")
    }

    @Test(arguments: ["javascript:alert(1)", "ftp://x.org", "mailto:a@b.c", "notaurl"])
    func nonWebLinksAreRefused(url: String) {
        #expect(router(rules).decide(url).action == .refuse)
    }

    @Test func filesOpenInTheFallback() {
        #expect(router(rules).decide("file:///tmp/a.html").action == .open(profile: primary, argument: "file:///tmp/a.html"))
    }

    @Test func noProfilesKnownStillFallsBackByDirectory() {
        let r = Router(rules: rules, script: nil, catalog: ProfileCatalog(profiles: []), fallback: ProfileRef(stored: "Default"))
        #expect(profile(of: r.decide("https://acme.com")) == "Default")
    }
}

@Suite struct LaunchPlanTests {
    @Test func linkGoesAfterTheSwitchTerminator() throws {
        let plan = try LaunchPlan.make(profile: work, argument: "https://app.acme.com/",
                                       catalog: catalog, ownBundleId: "dev.betterlink").get()
        #expect(plan.bundleId == "com.brave.Browser")
        #expect(plan.arguments == ["--profile-directory=Profile 1", "--", "https://app.acme.com/"])
    }

    @Test(arguments: ["--disable-web-security", "javascript:alert(1)", "chrome://settings", "https://a.com/\0x", ""])
    func nonLinkArgumentsAreRejected(arg: String) {
        #expect(LaunchPlan.make(profile: primary, argument: arg, catalog: catalog,
                                ownBundleId: "dev.betterlink") == .failure(.unsafeArgument))
    }

    @Test(arguments: ["Default --x", "Profile 0", "Profile 1 ", "../Default", "profile 1", "System Profile", "Guest Profile"])
    func onlyChromiumProfileFolderNamesAreAccepted(dir: String) {
        let p = BrowserProfile(directory: dir, name: "x", color: nil)
        #expect(!BrowserProfile.isValidDirectory(dir))
        #expect(LaunchPlan.make(profile: p, argument: "https://a.com",
                                catalog: ProfileCatalog(profiles: [p]), ownBundleId: "dev.betterlink") == .failure(.unknownProfile(dir)))
    }

    @Test func profileMustBeOneTheBrowserLists() {
        let fake = BrowserProfile(directory: "Default --disable-web-security", name: "x", color: nil)
        #expect(LaunchPlan.make(profile: fake, argument: "https://a.com", catalog: catalog,
                                ownBundleId: "dev.betterlink") == .failure(.unknownProfile(fake.directory)))
    }

    /// Review round 1, F1: with no stored profiles, links still open in the
    /// fallback profile instead of being dropped.
    @Test func fallbackOpensEvenWhenNoProfilesAreKnown() throws {
        let empty = ProfileCatalog(profiles: [])
        let d = Router(rules: [], script: nil, catalog: empty, fallback: ProfileRef(stored: "Default")).decide("https://a.com")
        guard case .open(let p, let arg) = d.action else { Issue.record("refused"); return }
        let plan = try LaunchPlan.make(profile: p, argument: arg, catalog: empty,
                                       fallback: ProfileRef(stored: "Default"), ownBundleId: "dev.betterlink").get()
        #expect(plan.arguments == ["--profile-directory=Default", "--", "https://a.com/"])
        // A fallback that isn't a profile folder name is still refused.
        let bad = BrowserProfile(directory: "Default --x", name: "x", color: nil)
        #expect(LaunchPlan.make(profile: bad, argument: arg, catalog: empty,
                                fallback: ProfileRef(stored: "Default --x"), ownBundleId: "dev.betterlink") == .failure(.unknownProfile("Default --x")))
    }

    @Test func refusesToTargetItself() {
        let me = BrowserProfile(browser: "dev.betterlink", directory: "Default", name: "me", color: nil)
        #expect(LaunchPlan.make(profile: me, argument: "https://a.com", catalog: ProfileCatalog(profiles: [me]),
                                ownBundleId: "dev.betterlink") == .failure(.targetsSelf))
    }

    @Test func unknownBrowsersAreRefused() {
        let p = BrowserProfile(browser: "com.example.notabrowser", directory: "Default", name: "x", color: nil)
        #expect(LaunchPlan.make(profile: p, argument: "https://a.com", catalog: ProfileCatalog(profiles: [p]),
                                ownBundleId: "dev.betterlink") == .failure(.unknownBrowser("com.example.notabrowser")))
    }

    @Test func firefoxOpensTheNamedProfile() throws {
        let p = BrowserProfile(browser: "org.mozilla.firefox", directory: "Work stuff", name: "Work stuff", color: nil)
        let plan = try LaunchPlan.make(profile: p, argument: "https://a.com/", catalog: ProfileCatalog(profiles: [p]),
                                       ownBundleId: "dev.betterlink").get()
        #expect(plan.bundleId == "org.mozilla.firefox")
        #expect(plan.arguments == ["-P", "Work stuff", "https://a.com/"])
    }

    @Test(arguments: ["-no-remote", "", "a\nb", "--headless"])
    func firefoxProfileNamesThatLookLikeSwitchesAreRefused(name: String) {
        let p = BrowserProfile(browser: "org.mozilla.firefox", directory: name, name: "x", color: nil)
        #expect(LaunchPlan.make(profile: p, argument: "https://a.com/", catalog: ProfileCatalog(profiles: [p]),
                                ownBundleId: "dev.betterlink") == .failure(.unknownProfile(name)))
    }

    @Test func browsersWithoutProfilesGetTheLinkTheOrdinaryWay() throws {
        let safari = BrowserProfile(browser: "com.apple.Safari", directory: "", name: "Safari", color: nil)
        let plan = try LaunchPlan.make(profile: safari, argument: "https://a.com/", catalog: ProfileCatalog(profiles: [safari]),
                                       ownBundleId: "dev.betterlink").get()
        #expect(plan.mode == .openURL("https://a.com/"))
        #expect(plan.arguments == [])
    }

    @Test func aLinkWithAControlCharacterIsRefused() {
        #expect(LaunchPlan.make(profile: primary, argument: "https://a.com/\nx", catalog: catalog,
                                ownBundleId: "dev.betterlink") == .failure(.unsafeArgument))
    }
}

@Suite struct ProfileCatalogTests {
    @Test func readsBraveLocalState() throws {
        let json = """
        {"profile":{"profiles_order":["Default","Profile 1"],"info_cache":{
          "Profile 1":{"name":"Work","profile_color_seed":-65281},
          "Default":{"name":"Primary","profile_color_seed":-4405517}}}}
        """
        let c = ProfileCatalog.parse(localStateJSON: Data(json.utf8))
        #expect(c.profiles.map(\.name) == ["Primary", "Work"])
        #expect(c.profile(named: "Work")?.directory == "Profile 1")
        #expect(c.profile(ProfileRef(browser: "com.brave.Browser", directory: "Profile 1"))?.color == 0xFF00FF)
    }

    @Test func readsFirefoxProfilesINI() {
        let ini = """
        [General]
        StartWithLastProfile=1
        Version=2

        [Profile1]
        Name=Work
        IsRelative=1
        Path=Profiles/abc.Work

        [Profile0]
        Name=default-release
        IsRelative=1
        Path=Profiles/xyz.default-release
        Default=1

        [Profile2]
        Name=-no-remote
        Path=Profiles/evil

        [Install4F96D1932A9F858E]
        Default=Profiles/xyz.default-release
        """
        let c = ProfileCatalog.parse(profilesINI: ini, browser: "org.mozilla.firefox")
        #expect(c.profiles.map(\.directory) == ["Work", "default-release"])
        #expect(c.profiles.allSatisfy { $0.browser == "org.mozilla.firefox" })
    }

    @Test func loadsEveryBrowserFromItsOwnFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bl-home-\(UUID().uuidString)")
        let support = home.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Google/Chrome"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("Firefox"), withIntermediateDirectories: true)
        try #"{"profile":{"info_cache":{"Default":{"name":"Me"}}}}"#.write(
            to: support.appendingPathComponent("Google/Chrome/Local State"), atomically: true, encoding: .utf8)
        try "[Profile0]\nName=Fox\n".write(to: support.appendingPathComponent("Firefox/profiles.ini"), atomically: true, encoding: .utf8)
        let browsers = ["com.google.Chrome", "org.mozilla.firefox", "com.apple.Safari", "com.brave.Browser"].compactMap(Browser.known(bundleId:))
        let c = ProfileCatalog.load(browsers: browsers, home: home)
        #expect(c.profiles.map(\.id) == ["com.google.Chrome|Default", "org.mozilla.firefox|Fox"])
    }

    @Test func profileNamesAreLookedUpWithinABrowserWhenTheyRepeat() {
        let c = ProfileCatalog(profiles: [
            BrowserProfile(browser: "com.brave.Browser", directory: "Profile 1", name: "Work", color: nil),
            BrowserProfile(browser: "com.google.Chrome", directory: "Profile 2", name: "Work", color: nil),
        ])
        #expect(c.profile(named: "Work") == nil)   // ambiguous
        #expect(c.profile(named: "Work", browser: "Google Chrome")?.directory == "Profile 2")
        #expect(c.profile(named: "Work", browser: "com.brave.Browser")?.directory == "Profile 1")
    }

    /// PR #3 review F1: a name two browsers share is reported as ambiguous.
    @Test func anAmbiguousNameFromConfigSaysSo() {
        let c = ProfileCatalog(profiles: [
            BrowserProfile(browser: "com.brave.Browser", directory: "Profile 1", name: "Work", color: nil),
            BrowserProfile(browser: "com.google.Chrome", directory: "Profile 2", name: "Work", color: nil),
            BrowserProfile(browser: "com.brave.Browser", directory: "Default", name: "Personal", color: nil),
        ])
        struct S: LinkScript { func route(_ l: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict { .profile("Work") } }
        let d = Router(rules: [], script: S(), catalog: c, fallback: ProfileRef(stored: "Default")).decide("https://a.com")
        #expect(d.reason.contains("more than one browser"))
        // The type check refuses the shared name, and keeps the unique one.
        let decls = configDeclarations(catalog: c)
        #expect(decls.contains(#"type ProfileName = "Personal";"#))
    }

    /// PR #3 round 2 follow-up: Safari alone (always installed) is not a
    /// profile to choose, so names stay open.
    @Test func onlySafariMeansAnyName() {
        let c = ProfileCatalog(profiles: []).addingPlain(installed: [Browser.known(bundleId: "com.apple.Safari")!])
        #expect(configDeclarations(catalog: c).contains("type ProfileName = string;"))
    }

    /// PR #3 round 2 follow-up: a name repeated inside one browser says so.
    @Test func aNameRepeatedInOneBrowserSaysSo() {
        let c = ProfileCatalog(profiles: [
            BrowserProfile(browser: "com.google.Chrome", directory: "Profile 1", name: "Person 1", color: nil),
            BrowserProfile(browser: "com.google.Chrome", directory: "Profile 2", name: "Person 1", color: nil),
        ])
        struct S: LinkScript { func route(_ l: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict { .profile("Person 1", browser: "Google Chrome") } }
        let d = Router(rules: [], script: S(), catalog: c, fallback: ProfileRef(stored: "Default")).decide("https://a.com")
        #expect(d.reason.contains("two Google Chrome profiles"))
        // Follow-up f4f9: without browser data access, only a rename in betterlink sticks.
        #expect(d.reason.contains("Edit Profiles"))
    }

    /// PR #5 review F1: a bare name repeated inside one browser is refused by
    /// the type check, and at run time the reason names the repeat.
    @Test func aBareNameRepeatedInOneBrowserIsRefused() {
        let c = ProfileCatalog(profiles: [
            BrowserProfile(browser: "com.google.Chrome", directory: "Profile 1", name: "Person 1", color: nil),
            BrowserProfile(browser: "com.google.Chrome", directory: "Profile 2", name: "Person 1", color: nil),
            BrowserProfile(browser: "com.google.Chrome", directory: "Profile 3", name: "Work", color: nil),
        ])
        #expect(configDeclarations(catalog: c).contains(#"type ProfileName = "Work";"#))
        struct S: LinkScript { func route(_ l: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict { .profile("Person 1") } }
        let d = Router(rules: [], script: S(), catalog: c, fallback: ProfileRef(stored: "Default")).decide("https://a.com")
        #expect(d.reason.contains("two Google Chrome profiles"))
        // Follow-up f4f9: without browser data access, only a rename in betterlink sticks.
        #expect(d.reason.contains("Edit Profiles"))
    }

    /// PR #5 review F1: when every name is repeated, no bare name type-checks.
    @Test func whenEveryNameRepeatsNoBareNameTypeChecks() {
        let c = ProfileCatalog(profiles: [
            BrowserProfile(browser: "com.google.Chrome", directory: "Profile 1", name: "Person 1", color: nil),
            BrowserProfile(browser: "com.google.Chrome", directory: "Profile 2", name: "Person 1", color: nil),
        ])
        #expect(configDeclarations(catalog: c).contains("type ProfileName = never;"))
    }

    /// PR #3 review F2: with no profiles, config.ts still type-checks names.
    @Test func noProfilesMeansAnyName() {
        let decls = configDeclarations(catalog: ProfileCatalog(profiles: []))
        #expect(decls.contains("type ProfileName = string;"))
        #expect(decls.contains("type BrowserName = string;"))
    }

    /// PR #3 review F3/F4: Safari and Arc are listed from what is installed,
    /// never stored, so they can't hide "no profiles yet" or come back after removal.
    @Test func plainBrowsersAreAddedFromWhatIsInstalled() {
        let stored = ProfileCatalog(profiles: [])
        let withSafari = stored.addingPlain(installed: [Browser.known(bundleId: "com.apple.Safari")!, .brave])
        #expect(withSafari.profiles.map(\.id) == ["com.apple.Safari|"])
        #expect(withSafari.hasProfilesToChoose == false)
        let real = ProfileCatalog(profiles: [primary]).addingPlain(installed: [])
        #expect(real.hasProfilesToChoose)
    }

    @Test func storedRulesAndProfilesFromBefore02AreBraves() throws {
        // The shape of a 0.1 rules.json: no browser on rules or profiles.
        let json = #"{"version":1,"rules":[{"id":"FD9A47C0-2A53-4451-9947-02921A30A4A9","kind":"startsWith","pattern":"https://github.com/acme","profile":"Profile 1"}],"profiles":[{"color":12371699,"directory":"Default","name":"Primary"}]}"#
        let c = try JSONDecoder().decode(RuleStore.Contents.self, from: Data(json.utf8))
        #expect(c.rules[0].browser == "com.brave.Browser")
        #expect(c.rules[0].target == ProfileRef(browser: "com.brave.Browser", directory: "Profile 1"))
        #expect(c.profiles?[0].browser == "com.brave.Browser")
        #expect(ProfileRef(stored: "Profile 1") == ProfileRef(browser: "com.brave.Browser", directory: "Profile 1"))
        #expect(ProfileRef(stored: "org.mozilla.firefox|Work") == ProfileRef(browser: "org.mozilla.firefox", directory: "Work"))
    }

    @Test func oddFolderNamesInLocalStateAreSkipped() {
        let json = #"{"profile":{"info_cache":{"Default":{"name":"A"},"Profile 1 --evil":{"name":"B"},"Guest Profile":{"name":"G"}}}}"#
        #expect(ProfileCatalog.parse(localStateJSON: Data(json.utf8)).profiles.map(\.directory) == ["Default"])
    }

    @Test func badFileGivesEmptyCatalog() {
        #expect(ProfileCatalog.parse(localStateJSON: Data("nope".utf8)).profiles.isEmpty)
        #expect(ProfileCatalog.load(browsers: [.brave], home: URL(fileURLWithPath: "/nonexistent")).profiles.isEmpty)
    }
}
