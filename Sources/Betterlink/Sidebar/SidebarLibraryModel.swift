import BetterlinkCore
import Foundation

/// The sidebar's Favorites and folders (sidebar.json in the settings folder),
/// for the sidebar and the Sidebar page. Every change is read-change-written on
/// disk under a lock, so the app and an agent never lose each other's edits.
@MainActor
final class SidebarLibraryModel: ObservableObject {
    static let shared = SidebarLibraryModel()

    @Published private(set) var library = SidebarLibrary.starter
    /// Why the last load or save failed, for the Sidebar page.
    @Published private(set) var problem: String?
    private var store = SidebarStore(folder: SettingsFolder.resolve())

    private init() { reload() }

    /// Reads sidebar.json again (for example after the settings folder changed).
    func reload(folder: SettingsFolder? = nil) {
        if let folder { store = SidebarStore(folder: folder) }
        PerfTrace.span("library reload") {
            do { library = try store.load(); problem = nil } catch { problem = error.localizedDescription }
        }
    }

    func change(_ body: (inout SidebarLibrary) -> Void) {
        do {
            library = try PerfTrace.span("store.update") { try store.update(body) }
            PerfTrace.published()
            problem = nil
        } catch { problem = error.localizedDescription }
    }

    func change(profile id: UUID, _ body: (inout SidebarProfile) -> Void) {
        change { $0.update(id, body) }
    }
}
