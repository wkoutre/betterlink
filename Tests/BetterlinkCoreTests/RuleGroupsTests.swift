import Foundation
import Testing
@testable import BetterlinkCore

/// Link Rules grouped by profile: the groups, saving one profile's rules
/// back into the full list, and the rules for other profiles whose order
/// decides where a link opens.
@Suite struct RuleGroupsTests {
    static let work = ProfileRef(browser: Browser.brave.bundleId, directory: "Profile 1")
    static let personal = ProfileRef(browser: Browser.brave.bundleId, directory: "Default")
    static let chrome = ProfileRef(browser: "com.google.Chrome", directory: "Default")

    func rule(_ kind: Rule.Kind = .domain, _ pattern: String, _ p: ProfileRef) -> Rule {
        Rule(kind: kind, pattern: pattern, browser: p.browser, profile: p.directory)
    }

    @Test func groupsFollowTheProfilesPageThenFirstAppearance() {
        let rules = [rule("a.com", Self.chrome), rule("b.com", Self.personal), rule("c.com", Self.work), rule("d.com", Self.personal)]
        let g = RuleGroups.groups(rules, order: [Self.work, Self.personal])
        #expect(g.map(\.target) == [Self.work, Self.personal, Self.chrome])
        #expect(g.map(\.positions) == [[2], [1, 3], [0]])
        // A profile without rules isn't listed.
        #expect(RuleGroups.groups([rule("a.com", Self.work)], order: [Self.personal, Self.work]).map(\.target) == [Self.work])
        #expect(RuleGroups.groups([], order: [Self.work]).isEmpty)
    }

    @Test func savingOneProfileKeepsEveryOtherRuleInPlace() {
        let a = rule("a.com", Self.work), b = rule("b.com", Self.personal), c = rule("c.com", Self.work), d = rule("d.com", Self.personal)
        let all = [a, b, c, d]
        // Reordered: Work's two places swap rules, Personal's stay put.
        #expect(RuleGroups.splice(all, profile: Self.work, edited: [c, a]) == [c, b, a, d])
        // Removed: the place goes.
        #expect(RuleGroups.splice(all, profile: Self.work, edited: [c]) == [c, b, d])
        // Added: new rules go last, so they never jump ahead of another profile's rule.
        let e = rule("e.com", Self.work)
        #expect(RuleGroups.splice(all, profile: Self.work, edited: [a, c, e]) == [a, b, c, d, e])
        // Moved to another profile in the sheet: it keeps its place.
        var a2 = a; a2.profile = Self.personal.directory
        #expect(RuleGroups.splice(all, profile: Self.work, edited: [a2, c]) == [a2, b, c, d])
        // Unchanged: unchanged.
        #expect(RuleGroups.splice(all, profile: Self.personal, edited: [b, d]) == all)
        // A profile with no rules yet.
        #expect(RuleGroups.splice(all, profile: Self.chrome, edited: [e]) == all + [e])
    }

    @Test func aWiderRuleAboveHidesANarrowerOneForAnotherProfile() {
        let rules = [rule("example.com", Self.personal), rule("app.example.com", Self.work)]
        let x = RuleGroups.crossings(rules)
        #expect(x == [.init(earlier: 0, later: 1, hidesLater: true, example: "https://app.example.com/")])
        // The same domain twice: the second never matches.
        #expect(RuleGroups.crossings([rule("a.com", Self.work), rule("a.com", Self.personal)]).map(\.hidesLater) == [true])
        // A domain above a link start on that domain.
        let s = RuleGroups.crossings([rule("github.com", Self.personal), rule(.startsWith, "https://github.com/acme", Self.work)])
        #expect(s.map(\.hidesLater) == [true])
        #expect(s.first?.example == "https://github.com/acme")
        // "URLs containing" above catches others' links.
        #expect(RuleGroups.crossings([rule(.contains, "acme", Self.personal), rule("acme.com", Self.work)]).map(\.hidesLater) == [true])
    }

    @Test func aNarrowerRuleAboveIsAnExceptionThatOrderKeeps() {
        let rules = [rule(.startsWith, "https://github.com/acme", Self.work), rule("github.com", Self.personal)]
        #expect(RuleGroups.crossings(rules) == [.init(earlier: 0, later: 1, hidesLater: false, example: "https://github.com/acme")])
        #expect(RuleGroups.crossings([rule("app.example.com", Self.work), rule("example.com", Self.personal)]).map(\.hidesLater) == [false])
    }

    @Test func rulesThatCantMeetOrShareAProfileDontCross() {
        // Same profile: order changes nothing.
        #expect(RuleGroups.crossings([rule("example.com", Self.work), rule("app.example.com", Self.work)]).isEmpty)
        // Different sites, and a look-alike.
        #expect(RuleGroups.crossings([rule("example.com", Self.work), rule("example.org", Self.personal),
                                       rule("evil-example.com", Self.chrome)]).isEmpty)
        // Different hosts, and a prefix that ends at a path boundary.
        #expect(RuleGroups.crossings([rule(.startsWith, "https://github.com/acme", Self.work),
                                       rule(.startsWith, "https://github.com/acmex", Self.personal)]).isEmpty)
        // A broken rule is skipped, as the router skips it.
        #expect(RuleGroups.crossings([rule("", Self.work), rule("a.com", Self.personal)]).isEmpty)
        // "URLs containing" below has no link of its own to test.
        #expect(RuleGroups.crossings([rule("acme.com", Self.work), rule(.contains, "zzz", Self.personal)]).isEmpty)
    }

    /// The crossing's example really does open where the earlier rule says.
    @Test func theExampleOpensInTheEarlierRulesProfile() {
        let rules = [rule("example.com", Self.personal), rule("app.example.com", Self.work),
                     rule(.startsWith, "https://github.com/acme", Self.work), rule("github.com", Self.personal)]
        for x in RuleGroups.crossings(rules) {
            guard case .web(let link) = LinkParser.parse(x.example) else { Issue.record("unparsable \(x.example)"); continue }
            #expect(rules.firstIndex { $0.matches(link) } == x.earlier)
            #expect(rules[x.later].matches(link))
        }
    }
}
