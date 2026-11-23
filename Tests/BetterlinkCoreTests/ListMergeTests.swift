import Foundation
import Testing
@testable import BetterlinkCore

/// Review F5: Done in a sheet saves the sheet's changes without dropping
/// what the CLI (or another Mac) changed while it was open.
@Suite struct ListMergeTests {
    func rule(_ pattern: String) -> Rule { Rule(kind: .domain, pattern: pattern, profile: "Default") }

    @Test func keepsARuleAddedElsewhereWhileTheSheetWasOpen() {
        let a = rule("a.com"), b = rule("b.com"), cli = rule("cli.com")
        let merged = ListMerge.merge(base: [a, b], mine: [a, b], theirs: [a, b, cli])
        #expect(merged == [a, b, cli])
    }

    @Test func theSheetsEditsDeletesAndOrderWin() {
        let a = rule("a.com"), b = rule("b.com"), c = rule("c.com")
        var a2 = a; a2.pattern = "a2.com"
        let new = rule("new.com")
        let merged = ListMerge.merge(base: [a, b, c], mine: [c, a2, new], theirs: [a, b, c])
        #expect(merged == [c, a2, new])
    }

    @Test func anUntouchedItemTakesTheVersionOnDiskOrStaysDeleted() {
        let a = rule("a.com"), b = rule("b.com")
        var bElsewhere = b; bElsewhere.profile = "Profile 1"
        #expect(ListMerge.merge(base: [a, b], mine: [a, b], theirs: [a, bElsewhere]) == [a, bElsewhere])
        #expect(ListMerge.merge(base: [a, b], mine: [a, b], theirs: [a]) == [a])
    }

    @Test func anEditKeptInTheSheetSurvivesADeleteElsewhere() {
        let a = rule("a.com")
        var a2 = a; a2.pattern = "a2.com"
        #expect(ListMerge.merge(base: [a], mine: [a2], theirs: []) == [a2])
    }

    /// The case the review reproduced: the CLI adds a rule through the store
    /// while the sheet is open, then Done saves through the store.
    @Test func doneThroughTheStoreKeepsTheCLIsRule() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bl-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let store = RuleStore(folder: SettingsFolder(directory: dir))
        let a = rule("a.com")
        try store.save(RuleStore.Contents(rules: [a]))
        let opened = try store.load().rules
        try store.update { $0.rules.append(rule("cli.com")) }   // the CLI, meanwhile
        var edited = opened; edited[0].pattern = "edited.com"
        try store.update { $0.rules = ListMerge.merge(base: opened, mine: edited, theirs: $0.rules) }
        #expect(try store.load().rules.map(\.pattern) == ["edited.com", "cli.com"])
    }
}
