import Foundation
import Testing
@testable import BetterlinkCore

@Suite struct RuleStoreTests {
    func tempStore() -> RuleStore {
        RuleStore(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("bl-\(UUID().uuidString)/rules.json"))
    }

    @Test func roundTripsAndIsPrivate() throws {
        let s = tempStore()
        #expect(try s.load() == RuleStore.Contents())
        let c = RuleStore.Contents(rules: [Rule(kind: .domain, pattern: "acme.com", profile: "Profile 1"),
                                           Rule(kind: .contains, pattern: "x", profile: "Default")],
                                   profiles: [primary, work])
        try s.save(c)
        #expect(try s.load() == c)
        let mode = try FileManager.default.attributesOfItem(atPath: s.file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    /// Review F8: saving through a symlinked rules.json updates the file it
    /// points to and leaves the link in place.
    @Test func savingKeepsASymlinkedRulesFile() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("bl-link-\(UUID().uuidString)", isDirectory: true)
        let real = base.appendingPathComponent("dotfiles", isDirectory: true)
        let folder = base.appendingPathComponent("settings", isDirectory: true)
        for d in [real, folder] { try fm.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let target = real.appendingPathComponent("rules.json")
        try RuleStore(file: target).save(RuleStore.Contents())
        let link = folder.appendingPathComponent("rules.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        let s = RuleStore(file: link)
        let c = RuleStore.Contents(rules: [Rule(kind: .domain, pattern: "acme.com", profile: "Default")])
        try s.save(c)
        #expect(try fm.destinationOfSymbolicLink(atPath: link.path) == target.path)
        #expect(try RuleStore(file: target).load() == c)
    }

    @Test func damagedFileIsAnErrorNotAnEmptyList() throws {
        let s = tempStore()
        try s.save(RuleStore.Contents())
        try "{nope".write(to: s.file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: s.file.path)
        #expect(throws: (any Error).self) { try s.load() }
    }

    @Test func unsafeFileIsRefused() throws {
        let s = tempStore()
        try s.save(RuleStore.Contents())
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: s.file.path)
        #expect(throws: (any Error).self) { try s.load() }
    }
}

@Suite struct LogBufferTests {
    @Test func keepsOnlyTheNewestEntries() {
        var log = LogBuffer(capacity: 3)
        for i in 1...5 { log.append(link: "https://\(i).com", opener: nil, profileName: "Primary", message: "m\(i)") }
        #expect(log.entries.map(\.message) == ["m3", "m4", "m5"])
    }

    @Test func recentLinksSkipConfigMessagesAndAreNewestFirst() {
        var log = LogBuffer()
        log.append(link: "https://a.com", opener: nil, profileName: "Primary", message: "a")
        log.append(link: nil, opener: nil, profileName: nil, message: "config loaded")
        log.append(link: "https://b.com", opener: nil, profileName: "Primary", message: "b")
        #expect(log.recentLinks().map(\.link) == ["https://b.com", "https://a.com"])
        #expect(log.recentLinks(1).count == 1)
    }
}

/// Review round 1, F1 and F2: a save must start from what is on disk now,
/// and a file that fails to load must never be overwritten.
@Suite struct RuleStoreUpdateTests {
    func tempStore() -> RuleStore {
        RuleStore(file: FileManager.default.temporaryDirectory
            .appendingPathComponent("bl-\(UUID().uuidString)/rules.json"))
    }

    @Test func savingRulesKeepsProfilesWrittenByAnotherProcess() throws {
        let s = tempStore()
        try s.save(RuleStore.Contents(rules: [], profiles: nil))
        // --import-profiles runs while the app holds an older copy.
        try s.save(RuleStore.Contents(rules: [], profiles: [primary, work]))
        let rule = Rule(kind: .domain, pattern: "acme.com", profile: "Profile 1")
        let saved = try s.update { $0.rules = [rule] }
        #expect(saved.profiles == [primary, work])
        #expect(try s.load() == RuleStore.Contents(rules: [rule], profiles: [primary, work]))
    }

    @Test func updateRefusesAFileThatDoesNotLoad() throws {
        let s = tempStore()
        let rule = Rule(kind: .domain, pattern: "acme.com", profile: "Profile 1")
        try s.save(RuleStore.Contents(rules: [rule], profiles: [primary]))
        try FileManager.default.setAttributes([.posixPermissions: 0o660], ofItemAtPath: s.file.path)
        #expect(throws: (any Error).self) { try s.update { $0.profiles = [] } }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: s.file.path)
        #expect(try s.load().rules == [rule])
    }
}
