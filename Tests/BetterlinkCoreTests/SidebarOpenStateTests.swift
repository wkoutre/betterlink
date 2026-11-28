import Foundation
import Testing
@testable import BetterlinkCore

/// Opening and closing folders is saved away from the click: the sidebar shows
/// the change at once and the file follows. These are the promises that makes.
struct SidebarOpenStateTests {
    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("betterlink-open-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("sidebar.json")
    }

    private func expanded(_ id: UUID, in lib: SidebarLibrary) -> Bool? {
        for p in lib.profiles { if let f = p.folder(id) { return f.expanded } }
        return nil
    }

    /// The change names where a folder ends up, so saving it twice, or after
    /// something else already put the folder there, changes nothing more.
    @Test func aChangeSaysWhereTheFolderEndsUpSoApplyingItAgainChangesNothing() {
        var p = SidebarProfile(name: "P")
        let a = p.addFolder("A")
        var lib = SidebarLibrary(profiles: [p])
        let close = SidebarOpenChange.folder(profile: p.id, id: a, open: false)
        close.apply(to: &lib)
        #expect(expanded(a, in: lib) == false)
        let once = lib
        close.apply(to: &lib)
        #expect(lib == once)
    }

    @Test func everyFolderOfOneProfileOpensOrCloses() {
        var p = SidebarProfile(name: "P"), q = SidebarProfile(name: "Q")
        let a = p.addFolder("A"), inner = p.addFolder("Inner", in: a), other = q.addFolder("Other")
        var lib = SidebarLibrary(profiles: [p, q])
        SidebarOpenChange.all(profile: p.id, open: false).apply(to: &lib)
        #expect(expanded(a, in: lib) == false)
        #expect(expanded(inner, in: lib) == false)
        #expect(expanded(other, in: lib) == true)
    }

    /// Clicks faster than the file is written: what is waiting is what the
    /// clicks add up to, in order.
    @Test func changesWaitingToBeSavedAddUpInOrder() {
        var p = SidebarProfile(name: "P")
        let a = p.addFolder("A"), b = p.addFolder("B")
        var lib = SidebarLibrary(profiles: [p])
        var waiting = SidebarOpenChanges()
        waiting.add(.folder(profile: p.id, id: a, open: false))
        waiting.add(.folder(profile: p.id, id: a, open: true))
        waiting.add(.folder(profile: p.id, id: b, open: false))
        // One entry per folder: the last word on it.
        #expect(waiting.changes == [.folder(profile: p.id, id: a, open: true), .folder(profile: p.id, id: b, open: false)])
        waiting.apply(to: &lib)
        #expect(expanded(a, in: lib) == true)
        #expect(expanded(b, in: lib) == false)

        // Option-click after single clicks takes their place; a click after it stays.
        waiting.add(.all(profile: p.id, open: false))
        #expect(waiting.changes == [.all(profile: p.id, open: false)])
        waiting.add(.folder(profile: p.id, id: a, open: true))
        waiting.apply(to: &lib)
        #expect(expanded(a, in: lib) == true)
        #expect(expanded(b, in: lib) == false)
        #expect(!waiting.isEmpty)
    }

    /// The app shows a folder open at once and saves a moment later. An edit
    /// the command line makes in between is in the file when the save reads
    /// it, and must still be there after.
    @Test func anEditMadeBetweenTheClickAndTheSaveSurvives() throws {
        let store = SidebarStore(file: tempFile())
        var folder: UUID!, profile: UUID!
        var shown = try store.update { lib in
            profile = lib.profiles[0].id
            lib.update(profile) { folder = $0.addFolder("Reading") }
        }
        // The click: on screen at once.
        let click = SidebarOpenChange.folder(profile: profile, id: folder, open: false)
        click.apply(to: &shown)
        // Meanwhile `betterlink sidebar add` saves a link.
        let link = SavedLink(title: "Docs", url: "https://example.com/docs")
        try store.update { $0.update(profile) { $0.addLink(link, in: folder) } }
        // The save: the click's change on what the file holds now.
        var waiting = SidebarOpenChanges()
        waiting.add(click)
        let saved = try store.save(waiting)
        #expect(saved.library.profiles[0].savedLink(link.id) != nil)
        #expect(expanded(folder, in: saved.library) == false)
        #expect(try store.load() == saved.library)
        // What is on screen ends equal to the file: the saved library with
        // whatever is still waiting (nothing here).
        #expect(saved.library != shown)
    }

    /// Whether folders are open doesn't sync, so a save that changed nothing
    /// else must be told apart from one that did.
    @Test func aSaveSaysWhetherItChangedOnlyWhichFoldersAreOpen() throws {
        let store = SidebarStore(file: tempFile())
        var folder: UUID!, profile: UUID!
        try store.update { lib in
            profile = lib.profiles[0].id
            lib.update(profile) { folder = $0.addFolder("Reading") }
        }
        let before = FileSignature.of(store.file)
        var waiting = SidebarOpenChanges()
        waiting.add(.folder(profile: profile, id: folder, open: false))
        let saved = try store.save(waiting)
        #expect(saved.before == before)
        #expect(saved.after == FileSignature.of(store.file))
        #expect(saved.after != before)
        #expect(saved.wrote)
        #expect(saved.onlyOpenFolders)
        // Already as asked: nothing is written, and the file is the one it was.
        let again = try store.save(waiting)
        #expect(!again.wrote)
        #expect(again.after == saved.after)
        #expect(FileSignature.of(store.file) == saved.after)
    }

    @Test func aFileSignatureChangesWhenTheFileOrItsPermissionsDo() throws {
        let file = tempFile()
        #expect(FileSignature.of(file) == nil)
        try Data("one".utf8).write(to: file, options: .atomic)
        let one = try #require(FileSignature.of(file))
        #expect(FileSignature.of(file) == one)
        try Data("two!".utf8).write(to: file, options: .atomic)
        let two = try #require(FileSignature.of(file))
        #expect(two != one)
        // The fix FileSafety asks for is a chmod: that must read as a change too.
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        #expect(FileSignature.of(file) != two)
    }

    /// Ignoring which folders are open, for "did anything that syncs change".
    @Test func librariesThatDifferOnlyInOpenFoldersAreTheSameApartFromThat() {
        var p = SidebarProfile(name: "P")
        let a = p.addFolder("A")
        let lib = SidebarLibrary(profiles: [p])
        var toggled = lib
        SidebarOpenChange.folder(profile: p.id, id: a, open: false).apply(to: &toggled)
        #expect(toggled != lib)
        #expect(toggled.sameApartFromOpenFolders(as: lib))
        var renamed = lib
        renamed.update(p.id) { $0.rename(a, to: "B") }
        #expect(!renamed.sameApartFromOpenFolders(as: lib))
    }
}
