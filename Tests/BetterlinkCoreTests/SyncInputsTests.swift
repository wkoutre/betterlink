import Foundation
import Testing
@testable import BetterlinkCore

/// What a sync reads, as file signatures: a pull started by a file watch is
/// skipped when none of them changed since the last pull, and opening or
/// closing a folder (which doesn't sync) leaves them as they were.
@Suite struct SyncInputsTests {
    private func folders() throws -> (SettingsFolder, SyncFolder) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-inputs-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home"), shared = root.appendingPathComponent("shared")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let sync = SyncFolder(shared)
        try FileManager.default.createDirectory(at: sync.devices, withIntermediateDirectories: true)
        return (SettingsFolder(directory: home), sync)
    }

    private func write(_ text: String, _ url: URL) throws {
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    @Test func unchangedFilesReadTheSame() throws {
        let (settings, sync) = try folders()
        try write("{}", settings.rulesFile)
        try write("{}", sync.file(for: "other"))
        #expect(SyncInputs.of(settings: settings, sync: sync) == SyncInputs.of(settings: settings, sync: sync))
    }

    @Test func aSavedSettingsFileOrADeviceFileIsAChange() throws {
        let (settings, sync) = try folders()
        try write("{}", settings.rulesFile)
        let before = SyncInputs.of(settings: settings, sync: sync)
        try write("{\"rules\":[]}", settings.rulesFile)
        let afterRules = SyncInputs.of(settings: settings, sync: sync)
        #expect(afterRules != before)
        try write("{}", sync.file(for: "other"))
        #expect(SyncInputs.of(settings: settings, sync: sync) != afterRules)
    }

    @Test func filesTheSyncDoesNotReadAreNotInputs() throws {
        let (settings, sync) = try folders()
        let before = SyncInputs.of(settings: settings, sync: sync)
        try write("log", settings.directory.appendingPathComponent("trace.log"))
        try write("", settings.directory.appendingPathComponent(".sidebar.lock"))
        #expect(SyncInputs.of(settings: settings, sync: sync) == before)
    }

    @Test func aSaveOfOpenFoldersAloneLeavesTheInputsAsTheyWere() throws {
        let (settings, sync) = try folders()
        let store = SidebarStore(folder: settings)
        var library = SidebarLibrary()
        let profile = SidebarProfile(name: "Primary")
        library.profiles = [profile]
        try SettingsFile.write(library, to: store.file, what: "sidebar.json")
        _ = try store.update { $0.update(profile.id) { _ = $0.addFolder("F") } }
        var seen = SyncInputs.of(settings: settings, sync: sync)
        let folder = try #require(store.load().profiles[0].items.first?.id)
        let saved = try store.save({ var c = SidebarOpenChanges(); c.add(.folder(profile: profile.id, id: folder, open: false)); return c }())
        #expect(saved.wrote && saved.onlyOpenFolders)
        #expect(SyncInputs.of(settings: settings, sync: sync) != seen)
        #expect(seen.moved(store.file, from: saved.before, to: saved.after))
        #expect(SyncInputs.of(settings: settings, sync: sync) == seen)
    }

    @Test func anOpenFolderSaveOnTopOfAnotherChangeIsNotTakenAsUnchanged() throws {
        let (settings, sync) = try folders()
        let store = SidebarStore(folder: settings)
        var library = SidebarLibrary()
        let profile = SidebarProfile(name: "Primary")
        library.profiles = [profile]
        try SettingsFile.write(library, to: store.file, what: "sidebar.json")
        var seen = SyncInputs.of(settings: settings, sync: sync)
        // Someone else (the command line) adds a folder after the last pull...
        _ = try store.update { $0.update(profile.id) { _ = $0.addFolder("F") } }
        let folder = try #require(store.load().profiles[0].items.first?.id)
        // ...and then this Mac only opens it: the file the save started from is not the one the pull saw.
        let saved = try store.save({ var c = SidebarOpenChanges(); c.add(.folder(profile: profile.id, id: folder, open: false)); return c }())
        #expect(!seen.moved(store.file, from: saved.before, to: saved.after))
        #expect(SyncInputs.of(settings: settings, sync: sync) != seen)
    }
}
