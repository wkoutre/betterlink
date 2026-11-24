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

    /// Review F2 (#14): the sidebar's Favorites and folders move with the rules.
    @Test func switchingFoldersCarriesTheSidebarLibrary() throws {
        let a = SettingsFolder(directory: try temp()), b = SettingsFolder(directory: try temp())
        try SidebarStore(folder: a).update { lib in lib.update(lib.profiles[0].id) { $0.addFolder("Travel") } }
        try a.copySettings(to: b)
        #expect(try SidebarStore(folder: b).load().profiles[0].items.count == 1)
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

    /// Security audit, Nov 2026: `folder.set` copied whatever a symlinked
    /// rules.json or config.ts pointed at. Any program can plant such a link
    /// (and choose the settings folder), so with Full Disk Access betterlink
    /// would copy a file that program may not read to where it can. The new
    /// folder gets a link to the same file instead; nothing is read.
    @Test func switchingFoldersLinksASymlinkedFileInsteadOfCopyingItsTarget() throws {
        let fm = FileManager.default
        let elsewhere = try temp()
        let secret = elsewhere.appendingPathComponent("private.txt")
        try "not betterlink's to copy".write(to: secret, atomically: true, encoding: .utf8)
        let dotfiles = elsewhere.appendingPathComponent("rules.json")
        try RuleStore(file: dotfiles).save(RuleStore.Contents(rules: [Rule(kind: .domain, pattern: "acme.com", profile: "Default")]))

        let a = SettingsFolder(directory: try temp()), b = SettingsFolder(directory: try temp())
        try fm.createSymbolicLink(at: a.configFile, withDestinationURL: secret)
        // A relative link, as a dotfiles manager makes: it must still resolve from the new folder.
        try fm.createSymbolicLink(atPath: a.rulesFile.path,
                                  withDestinationPath: "../\(elsewhere.lastPathComponent)/rules.json")
        try a.copySettings(to: b)

        for (file, target) in [(b.configFile, secret), (b.rulesFile, dotfiles)] {
            let type = try fm.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType
            #expect(type == .typeSymbolicLink, "\(file.lastPathComponent) must be a link, not a copy")
            #expect(try fm.destinationOfSymbolicLink(atPath: file.path) == target.resolvingSymlinksInPath().path)
        }
        // The linked rules still load from the new folder, and a save goes to the one shared file.
        #expect(try RuleStore(folder: b).load().rules.count == 1)
        try RuleStore(folder: b).update { $0.rules.removeAll() }
        #expect(try RuleStore(file: dotfiles).load().rules.isEmpty)
    }

    /// A plain file is still copied, so the two folders stay independent.
    @Test func switchingFoldersStillCopiesPlainFiles() throws {
        let a = SettingsFolder(directory: try temp()), b = SettingsFolder(directory: try temp())
        try "// a".write(to: a.configFile, atomically: true, encoding: .utf8)
        try a.copySettings(to: b)
        let type = try FileManager.default.attributesOfItem(atPath: b.configFile.path)[.type] as? FileAttributeType
        #expect(type == .typeRegular)
        try "// changed".write(to: a.configFile, atomically: true, encoding: .utf8)
        #expect(try String(contentsOf: b.configFile, encoding: .utf8) == "// a")
    }
}
