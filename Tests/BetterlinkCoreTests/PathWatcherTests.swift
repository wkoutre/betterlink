import Foundation
import Testing
@testable import BetterlinkCore

/// PR #2 review F1: the fix FileSafety asks for (chmod go-w) must be noticed,
/// for a watched file and for a watched folder.
@Suite(.serialized) struct PathWatcherTests {
    func fires(watching url: URL, after change: () throws -> Void) throws -> Bool {
        let q = DispatchQueue(label: "watch-test")
        let hit = DispatchSemaphore(value: 0)
        let w = PathWatcher(url: url, queue: q, debounce: 0) { hit.signal() }
        try #require(w != nil)
        try change()
        let ok = hit.wait(timeout: .now() + 2) == .success
        withExtendedLifetime(w) {}
        return ok
    }

    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("bl-w-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return d
    }

    @Test func noticesChmodOnAFile() throws {
        let f = try tempDir().appendingPathComponent("rules.json")
        try "{}".write(to: f, atomically: true, encoding: .utf8)
        #expect(try fires(watching: f) { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: f.path) })
    }

    @Test func noticesChmodOnAFolder() throws {
        let d = try tempDir()
        #expect(try fires(watching: d) { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: d.path) })
    }

    @Test func noticesAnInPlaceSave() throws {
        let f = try tempDir().appendingPathComponent("config.ts")
        try "a".write(to: f, atomically: true, encoding: .utf8)
        #expect(try fires(watching: f) {
            let h = try FileHandle(forWritingTo: f); try h.truncate(atOffset: 0); try h.write(contentsOf: Data("b".utf8)); try h.close()
        })
    }
}
