import Foundation
import Testing
@testable import TabSyncCore

struct ExtensionCopyTests {
    /// A folder that looks like the extension: a manifest with a version and a
    /// key, plus the files given.
    func make(_ version: String?, key: String = "KEY", files: [String: String] = ["background.js": "a", "icons/16.png": "i"]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bl-ext-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let version {
            try write(#"{"version":"\#(version)","key":"\#(key)"}"#, "manifest.json", in: dir)
        }
        for (name, body) in files { try write(body, name, in: dir) }
        return dir
    }
    func write(_ body: String, _ name: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url)
    }
    func read(_ name: String, in dir: URL) -> String? {
        (try? Data(contentsOf: dir.appendingPathComponent(name))).map { String(decoding: $0, as: UTF8.self) }
    }
    func empty() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bl-ext-\(UUID().uuidString)/nested/extension")
    }

    @Test func aMissingFolderGetsEveryFile() throws {
        let source = try make("0.3.0")
        let dest = empty()
        #expect(try ExtensionCopy.refresh(from: source, to: dest) == .installed("0.3.0"))
        #expect(ExtensionCopy.version(of: dest) == "0.3.0")
        #expect(read("background.js", in: dest) == "a")
        #expect(read("icons/16.png", in: dest) == "i")
        // A second run finds nothing to do.
        #expect(try ExtensionCopy.refresh(from: source, to: dest) == .current)
    }

    @Test func aNewerVersionReplacesTheFilesAndDropsOnesItNoLongerHas() throws {
        let dest = try make("0.2.0", files: ["background.js": "old", "gone.js": "x"])
        let source = try make("0.3.0", files: ["background.js": "new", "bridge.js": "b"])
        #expect(try ExtensionCopy.refresh(from: source, to: dest) == .updated(from: "0.2.0", to: "0.3.0"))
        #expect(read("background.js", in: dest) == "new")
        #expect(read("bridge.js", in: dest) == "b")
        #expect(read("gone.js", in: dest) == nil)
        #expect(ExtensionCopy.version(of: dest) == "0.3.0")
    }

    @Test func theSameVersionWithOtherContentsIsRefreshed() throws {
        let dest = try make("0.3.0", files: ["background.js": "old"])
        let source = try make("0.3.0", files: ["background.js": "new"])
        #expect(try ExtensionCopy.refresh(from: source, to: dest) == .updated(from: "0.3.0", to: "0.3.0"))
        #expect(read("background.js", in: dest) == "new")
    }

    /// Two betterlinks on one Mac (a release and an older one): the browser
    /// keeps the newer extension.
    @Test func aNewerCopyInTheFolderIsNeverDowngraded() throws {
        let dest = try make("0.10.0", files: ["background.js": "newer"])
        let source = try make("0.9.1", files: ["background.js": "older"])
        #expect(try ExtensionCopy.refresh(from: source, to: dest) == .kept(newer: "0.10.0"))
        #expect(read("background.js", in: dest) == "newer")
    }

    @Test func aFolderHoldingSomethingElseIsLeftAlone() throws {
        let source = try make("0.3.0")
        // Files but no manifest.
        let stray = try make(nil, files: ["notes.txt": "mine"])
        #expect(throws: ExtensionCopy.Failure.notOurs(stray.path)) { try ExtensionCopy.refresh(from: source, to: stray) }
        #expect(read("notes.txt", in: stray) == "mine")
        #expect(read("background.js", in: stray) == nil)
        // Another extension (another key).
        let other = try make("0.1.0", key: "OTHER", files: ["background.js": "theirs"])
        #expect(throws: ExtensionCopy.Failure.notOurs(other.path)) { try ExtensionCopy.refresh(from: source, to: other) }
        #expect(read("background.js", in: other) == "theirs")
    }

    @Test func aSourceWithoutAManifestIsRefused() throws {
        let source = try make(nil)
        #expect(throws: ExtensionCopy.Failure.noExtension(source.path)) { try ExtensionCopy.refresh(from: source, to: empty()) }
        #expect(ExtensionCopy.version(of: source) == nil)
    }

    @Test func versionsCompareByNumberNotByText() {
        #expect(ExtensionCopy.compare("0.10.0", "0.9.1") == .orderedDescending)
        #expect(ExtensionCopy.compare("0.3", "0.3.0") == .orderedSame)
        #expect(ExtensionCopy.compare("0.2.9", "0.3.0") == .orderedAscending)
    }

    @Test func aRunningCopyIsAskedToReloadOnlyWhenItCanAndRunsAnotherVersion() {
        #expect(ExtensionCopy.shouldReload(running: "0.3.0", folderVersion: "0.3.1", canReload: true))
        #expect(!ExtensionCopy.shouldReload(running: "0.3.1", folderVersion: "0.3.1", canReload: true))
        // 0.2.0 has no reloadSelf: it is reloaded by hand once.
        #expect(!ExtensionCopy.shouldReload(running: "0.2.0", folderVersion: "0.3.1", canReload: false))
        // No hello yet, or no managed folder.
        #expect(!ExtensionCopy.shouldReload(running: nil, folderVersion: "0.3.1", canReload: true))
        #expect(!ExtensionCopy.shouldReload(running: "0.3.0", folderVersion: nil, canReload: true))
    }

    /// A test or development run (BETTERLINK_HOME) never touches the folder a
    /// browser really loads the extension from.
    @Test func theFolderMovesWithTheTestOverrides() {
        #expect(ExtensionCopy.folder(environment: ["BETTERLINK_TABS_EXTENSION_DIR": "/tmp/x", "BETTERLINK_HOME": "/tmp/h"]).path == "/tmp/x")
        #expect(ExtensionCopy.folder(environment: ["BETTERLINK_HOME": "/tmp/h"]).path == "/tmp/h/tabs-extension")
        #expect(!ExtensionCopy.folder(environment: [:]).path.contains("/tmp/h"))
    }

    /// The extension in the repository is one that can reload itself.
    @Test func theExtensionThatShipsIsNewEnoughToReloadItself() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let version = try #require(ExtensionCopy.version(of: root.appendingPathComponent("browser-extension")))
        #expect(ExtensionCopy.compare(version, "0.3.0") != .orderedAscending, "reloadSelf arrived with 0.3.0")
    }
}
