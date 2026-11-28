import BetterlinkCore
import Foundation
import os

/// The sidebar's Favorites and folders (sidebar.json in the settings folder),
/// for the sidebar and the Sidebar page. Every change is read-change-written on
/// disk under a lock, so the app and an agent never lose each other's edits.
///
/// Opening and closing folders is the one change made on a click that then
/// animates, so it is shown at once and saved off the main thread (`setOpen`).
/// Reading, changing and writing sidebar.json took 5 to 11 ms of the click with
/// 200 saved links (measured with PerfTrace). Every other edit is still saved
/// before it shows.
@MainActor
final class SidebarLibraryModel: ObservableObject {
    static let shared = SidebarLibraryModel()

    @Published private(set) var library = SidebarLibrary.starter
    /// Why the last load or save failed, for the Sidebar page.
    @Published private(set) var problem: String?
    /// Goes up with every change to the library but opening and closing
    /// folders. A sidebar row is drawn again only when what it shows changes,
    /// and its menus and drop places come from the rest of the library (the
    /// folders to move to, where it sits): comparing this stands for that.
    private(set) var shape = 0
    private var store = SidebarStore(folder: SettingsFolder.resolve())

    /// sidebar.json as this last read or wrote it. While the file is still
    /// that one it isn't read again: the settings folder's watch also fires
    /// for this app's own saves and for the other files in the folder.
    private var seen: FileSignature?
    /// Folders opened or closed on screen and not in the file yet: those
    /// still to be written, and those being written now.
    private var waiting = SidebarOpenChanges()
    private var writing = SidebarOpenChanges()
    private var isWriting = false
    private let writer = DispatchQueue(label: "betterlink.sidebar.save", qos: .userInitiated)
    private enum Outcome: Sendable { case saved(SidebarStore.Saved), failed(String) }
    /// The write's outcome, handed back to the main thread.
    private let outcome = OSAllocatedUnfairLock<Outcome?>(initialState: nil)

    private init() { reload() }

    /// Reads sidebar.json again (for example after the settings folder changed).
    func reload(folder: SettingsFolder? = nil) {
        if let folder {
            flush()
            store = SidebarStore(folder: folder)
            seen = nil
        }
        let now = FileSignature.of(store.file)
        if now != nil, now == seen, problem == nil { return }
        PerfTrace.span("library reload") {
            do { show(try store.load()); seen = now; problem = nil } catch { problem = error.localizedDescription }
        }
    }

    /// Shows what the file holds, with the folders opened or closed since on
    /// top. A library equal to the one showing is not published again: every
    /// sidebar would redraw, unanimated, for nothing.
    private func show(_ fromFile: SidebarLibrary) {
        var next = fromFile
        writing.apply(to: &next)
        waiting.apply(to: &next)
        guard next != library else { return }
        if !next.sameApartFromOpenFolders(as: library) { shape += 1 }
        library = next
        PerfTrace.published()
    }

    func change(_ body: (inout SidebarLibrary) -> Void) {
        // Nothing of an earlier click is on its way to the file any more, and
        // what still waits is written with this edit, before it.
        finishWriting()
        let unsaved = waiting
        do {
            let saved = try PerfTrace.span("store.update") {
                try store.change { library in
                    unsaved.apply(to: &library)
                    body(&library)
                }
            }
            waiting = SidebarOpenChanges()
            seen = saved.after
            problem = nil
            show(saved.library)
        } catch { problem = error.localizedDescription }
    }

    func change(profile id: UUID, _ body: (inout SidebarProfile) -> Void) {
        change { $0.update(id, body) }
    }

    /// Opens or closes folders: on screen now, in the file a moment later.
    /// The change names where they end up, so it is saved on top of whatever
    /// the file holds by then (`SidebarStore.save`).
    func setOpen(_ change: SidebarOpenChange) {
        var next = library
        change.apply(to: &next)
        guard next != library else { return }
        library = next
        PerfTrace.published()
        waiting.add(change)
        write()
    }

    /// Writes what waits, one write at a time: clicks made during a write go
    /// out together in the next.
    private func write() {
        guard !isWriting, !waiting.isEmpty else { return }
        isWriting = true
        writing = waiting
        waiting = SidebarOpenChanges()
        let store = store, changes = writing, outcome = outcome
        writer.async {
            let result: Outcome
            do { result = .saved(try store.save(changes)) } catch { result = .failed(error.localizedDescription) }
            outcome.withLock { $0 = result }
            DispatchQueue.main.async { MainActor.assumeIsolated { SidebarLibraryModel.shared.wrote(thenWrite: true) } }
        }
    }

    /// Takes a finished write's outcome. Once only: the main thread may have
    /// come for it early (`finishWriting`).
    private func wrote(thenWrite: Bool) {
        guard let result = outcome.withLock({ held -> Outcome? in defer { held = nil }; return held }) else { return }
        isWriting = false
        writing = SidebarOpenChanges()
        switch result {
        case .saved(let saved):
            problem = nil
            seen = saved.after
            if saved.wrote, saved.onlyOpenFolders { SyncController.shared.savedOnlyOpenFolders(before: saved.before, after: saved.after) }
            // The file with what still waits on top: what is on screen
            // already, unless someone else changed the file meanwhile.
            show(saved.library)
        case .failed(let why):
            // Not saved: the screen goes back to what the file has, as an
            // edit that can't be saved never shows.
            problem = why
            seen = nil
            if let onDisk = try? store.load() { show(onDisk) }
        }
        if thenWrite { write() }
    }

    /// Waits for a write under way (a few milliseconds).
    private func finishWriting() {
        guard isWriting else { return }
        writer.sync {}
        wrote(thenWrite: false)
    }

    /// Saves anything not in the file yet, before returning: at quit, and
    /// before another settings folder is used.
    func flush() {
        finishWriting()
        guard !waiting.isEmpty else { return }
        let unsaved = waiting
        waiting = SidebarOpenChanges()
        do {
            let saved = try store.save(unsaved)
            seen = saved.after
            if saved.wrote, saved.onlyOpenFolders { SyncController.shared.savedOnlyOpenFolders(before: saved.before, after: saved.after) }
        } catch { problem = error.localizedDescription }
    }
}
