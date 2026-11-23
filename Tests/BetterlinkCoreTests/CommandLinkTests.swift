import Foundation
import Testing
@testable import BetterlinkCore

/// Install Command's link logic, run in a temp folder (never the real ~/.local/bin).
@Suite final class CommandLinkTests {
    let root: URL
    let fm = FileManager.default

    init() throws {
        root = fm.temporaryDirectory.appendingPathComponent("bl-link-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// An executable at <root>/<app>/Contents/Helpers/betterlink.
    func helper(_ app: String) throws -> URL {
        let u = root.appendingPathComponent("\(app)/Contents/Helpers/betterlink")
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: u.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return u
    }

    var linkURL: URL { root.appendingPathComponent("home/.local/bin/betterlink") }

    @Test func installsWhenNothingIsThere() throws {
        let link = CommandLink(link: linkURL, bundled: try helper("betterlink.app"))
        #expect(link.status() == .notInstalled)
        try link.install()
        #expect(link.status() == .installed)
    }

    @Test func aRelativeLinkToThisCopyCountsAsInstalled() throws {
        let bundled = try helper("betterlink.app")
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "../../../betterlink.app/Contents/Helpers/betterlink")
        #expect(CommandLink(link: linkURL, bundled: bundled).status() == .installed)
    }

    @Test func anotherBetterlinkCopyIsReplacedOnReinstall() throws {
        let old = try helper("Old/betterlink.app")
        let bundled = try helper("betterlink.app")
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: old)
        let link = CommandLink(link: linkURL, bundled: bundled)
        #expect(link.status() == .pointsElsewhere(old.standardizedFileURL.path))
        try link.install()
        #expect(link.status() == .installed)
    }

    @Test func anotherToolsLinkIsLeftAlone() throws {
        let theirs = root.appendingPathComponent("share/tool/bin/betterlink")
        try fm.createDirectory(at: theirs.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: theirs.path, contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: theirs)
        let link = CommandLink(link: linkURL, bundled: try helper("betterlink.app"))
        #expect(link.status() == .blocked)
        #expect(throws: CommandLink.Problem.self) { try link.install() }
        #expect(throws: CommandLink.Problem.self) { try link.uninstall() }
        #expect(try fm.destinationOfSymbolicLink(atPath: linkURL.path) == theirs.path)
    }

    @Test func aRealFileIsLeftAlone() throws {
        try fm.createDirectory(at: linkURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: linkURL.path, contents: Data("mine".utf8))
        let link = CommandLink(link: linkURL, bundled: try helper("betterlink.app"))
        #expect(link.status() == .blocked)
        #expect(throws: CommandLink.Problem.self) { try link.install() }
        #expect(try String(contentsOf: linkURL, encoding: .utf8) == "mine")
    }

    @Test func uninstallRemovesOnlyItsLink() throws {
        let bundled = try helper("betterlink.app")
        let link = CommandLink(link: linkURL, bundled: bundled)
        try link.install()
        try link.uninstall()
        #expect(link.status() == .notInstalled)
        #expect(fm.isExecutableFile(atPath: bundled.path))
    }

    @Test func aCopyWithoutTheCommandRefusesToInstall() throws {
        let link = CommandLink(link: linkURL, bundled: root.appendingPathComponent("none.app/Contents/Helpers/betterlink"))
        #expect(throws: CommandLink.Problem.self) { try link.install() }
        #expect(link.status() == .notInstalled)
    }
}
