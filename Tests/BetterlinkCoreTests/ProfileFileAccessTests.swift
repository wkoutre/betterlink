import Foundation
import Testing
@testable import BetterlinkCore

/// A browser's profile list can be unreadable for reasons other than Full
/// Disk Access (a work Mac's security software refuses with it granted).
/// These pin that betterlink tells the reasons apart instead of always
/// saying "Not allowed".
@Suite struct ProfileFileAccessTests {
    private func tempHome() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bl-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func writeLocalState(_ b: Browser, home: URL, mode: Int = 0o600) throws -> URL {
        let file = b.profilesFile(home: home)!
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Me"}}}}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        return file
    }

    @Test func classifiesErrnos() {
        #expect(ProfileFileAccess.classify(errno: ENOENT) == .missing)
        #expect(ProfileFileAccess.classify(errno: EPERM) == .blocked)
        #expect(ProfileFileAccess.classify(errno: EACCES) == .filePermissions)
        #expect(ProfileFileAccess.classify(errno: EIO) == .failed(String(cString: strerror(EIO))))
    }

    @Test func checksRealFiles() throws {
        let home = try tempHome()
        let chrome = Browser.known(bundleId: "com.google.Chrome")!
        #expect(ProfileFileAccess.check(chrome.profilesFile(home: home)!) == .missing)
        let file = try writeLocalState(chrome, home: home)
        #expect(ProfileFileAccess.check(file) == .readable)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        if getuid() != 0 { #expect(ProfileFileAccess.check(file) == .filePermissions) }
    }

    /// The reported bug: Full Disk Access granted, read still refused. The
    /// message must not send the user back to Full Disk Access.
    @Test func blockedWithFullDiskAccessBlamesSomethingElse() {
        let on = ProfileFileAccess.blocked.explanation(browser: "Brave", fullDiskAccess: true) ?? ""
        #expect(on.contains("Full Disk Access is on"))
        #expect(on.contains("security software"))
        #expect(!on.contains("Allow Full Disk Access"))
        #expect(ProfileFileAccess.blocked.badge(fullDiskAccess: true) == "Blocked")

        for fda in [false, nil] as [Bool?] {
            let off = ProfileFileAccess.blocked.explanation(browser: "Brave", fullDiskAccess: fda) ?? ""
            #expect(off.contains("Allow Full Disk Access"))
            #expect(ProfileFileAccess.blocked.badge(fullDiskAccess: fda) == "Not allowed")
        }
    }

    @Test func otherStatesExplainThemselves() {
        #expect(ProfileFileAccess.readable.explanation(browser: "Brave", fullDiskAccess: nil) == nil)
        #expect(ProfileFileAccess.missing.explanation(browser: "Brave", fullDiskAccess: nil) == nil)
        #expect(ProfileFileAccess.readable.badge(fullDiskAccess: nil) == "Readable")
        #expect(ProfileFileAccess.missing.badge(fullDiskAccess: nil) == "No profiles yet")
        #expect(ProfileFileAccess.filePermissions.explanation(browser: "Brave", fullDiskAccess: true)?.contains("file permissions") == true)
        #expect(ProfileFileAccess.failed("Input/output error").explanation(browser: "Brave", fullDiskAccess: true)
                == "Couldn't read Brave's profiles: Input/output error.")
    }

    @Test func fullDiskAccessProbe() throws {
        let home = try tempHome()
        let probe = FullDiskAccess.probeFile(home: home)
        #expect(probe.path.hasSuffix("Library/Application Support/com.apple.TCC/TCC.db"))
        #expect(FullDiskAccess.isGranted(probe: probe) == nil)
        try FileManager.default.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: probe)
        #expect(FullDiskAccess.isGranted(probe: probe) == true)
    }

    @Test func importFailureSaysWhyPerBrowser() throws {
        let home = try tempHome()
        let brave = Browser.brave
        let chrome = Browser.known(bundleId: "com.google.Chrome")!
        let file = try writeLocalState(chrome, home: home, mode: 0o000)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        let message = Agent.importFailure([brave, chrome], home: home, fullDiskAccess: true)
        #expect(message.hasPrefix("Couldn't read profiles from Brave, Google Chrome."))
        #expect(message.contains("Brave has no profile list yet"))
        if getuid() != 0 { #expect(message.contains("file permissions")) }
        #expect(!message.contains("Allow Full Disk Access"))
    }
}
