import Foundation
import Testing
@testable import BetterlinkCore

@Suite struct SettingsFolderTests {
    func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }

    @Test func environmentThenChosenFolderThenStandard() throws {
        let defaults = try #require(UserDefaults(suiteName: "bl-test-\(UUID().uuidString)"))
        #expect(SettingsFolder.resolve(environment: [:], defaults: defaults).directory == SettingsFolder.defaultDirectory)
        #expect(SettingsFolder.defaultDirectory.path.hasSuffix("Library/Application Support/betterlink"))
        defaults.set("/tmp/chosen", forKey: SettingsFolder.defaultsKey)
        #expect(SettingsFolder.resolve(environment: [:], defaults: defaults).directory.path == "/tmp/chosen")
        #expect(SettingsFolder.resolve(environment: ["BETTERLINK_HOME": "/tmp/env"], defaults: defaults).directory.path == "/tmp/env")
    }

    @Test func adoptsTheOldConfigOnceWithoutOverwriting() throws {
        let old = try temp().appendingPathComponent("config.ts")
        try "// old".write(to: old, atomically: true, encoding: .utf8)
        let folder = SettingsFolder(directory: try temp())
        #expect(try folder.adoptLegacyConfig(from: old))
        #expect(try String(contentsOf: folder.configFile, encoding: .utf8) == "// old")
        try "// new".write(to: folder.configFile, atomically: true, encoding: .utf8)
        #expect(try !folder.adoptLegacyConfig(from: old))
        #expect(try String(contentsOf: folder.configFile, encoding: .utf8) == "// new")
    }

    @Test func switchingFoldersCopiesSettingsButNeverOverwrites() throws {
        let a = SettingsFolder(directory: try temp()), b = SettingsFolder(directory: try temp())
        try RuleStore(folder: a).save(RuleStore.Contents(rules: [Rule(kind: .domain, pattern: "acme.com", profile: "Default")]))
        try "// a".write(to: a.configFile, atomically: true, encoding: .utf8)
        try "// b".write(to: b.configFile, atomically: true, encoding: .utf8)
        try a.copySettings(to: b)
        #expect(try RuleStore(folder: b).load().rules.count == 1)
        #expect(try String(contentsOf: b.configFile, encoding: .utf8) == "// b")
    }

    @Test func refusesAFolderOthersCanWrite() throws {
        let a = SettingsFolder(directory: try temp()), b = SettingsFolder(directory: try temp())
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: b.directory.path)
        #expect(throws: (any Error).self) { try a.copySettings(to: b) }
    }

    /// PR #2 review F2: copying never launders a file FileSafety would refuse.
    @Test func adoptRefusesAnUnsafeOldConfig() throws {
        let oldDir = try temp()
        let old = oldDir.appendingPathComponent("config.ts")
        try "// old".write(to: old, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: oldDir.path)
        let folder = SettingsFolder(directory: try temp())
        #expect(throws: (any Error).self) { try folder.adoptLegacyConfig(from: old) }
        #expect(!FileManager.default.fileExists(atPath: folder.configFile.path))
    }

    @Test func switchingRefusesUnsafeSourceFiles() throws {
        let a = SettingsFolder(directory: try temp()), b = SettingsFolder(directory: try temp())
        try RuleStore(folder: a).save(RuleStore.Contents())
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: a.rulesFile.path)
        #expect(throws: (any Error).self) { try a.copySettings(to: b) }
        #expect(!FileManager.default.fileExists(atPath: b.rulesFile.path))
    }

}
