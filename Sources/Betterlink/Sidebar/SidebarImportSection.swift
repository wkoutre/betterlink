import AppKit
import BetterlinkCore
import SwiftUI
import UniformTypeIdentifiers

/// Brings in what someone already built elsewhere: Arc's sidebar (each Space
/// becomes a Sidebar Profile), a browser's bookmarks, or a bookmarks.html
/// file. Everything is read from files on this Mac (SidebarImport).
struct SidebarImportSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var lib = SidebarLibraryModel.shared
    /// The Sidebar Profile bookmarks go into; nil is the first one.
    @State private var into: UUID?
    @State private var result: String?
    @State private var failed = false
    @State private var sources: [BookmarkSource] = []

    /// A browser profile's Bookmarks file.
    struct BookmarkSource: Identifiable, Equatable {
        var browser: String
        var profile: String
        var file: URL
        var id: String { file.path }
        var label: String { "\(browser) · \(profile)" }
    }

    private static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }
    private static var arcFile: URL { support.appendingPathComponent("Arc/StorableSidebar.json") }

    private var target: SidebarProfile? {
        lib.library.profiles.first { $0.id == into } ?? lib.library.profiles.first
    }

    var body: some View {
        DSSection {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Arc")
                    Text("Each Space becomes a Sidebar Profile with its Favorites, pinned tabs and folders.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Import from Arc") { importArc(Self.arcFile) }
                    .disabled(!FileManager.default.fileExists(atPath: Self.arcFile.path))
                    .help(FileManager.default.fileExists(atPath: Self.arcFile.path) ? "Reads Arc's sidebar file on this Mac" : "Arc's sidebar file isn't on this Mac")
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bookmarks")
                    Text("Added as one closed folder in \u{201C}\(target?.name ?? "the sidebar")\u{201D}.")
                        .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if lib.library.profiles.count > 1 {
                    Picker("Into", selection: Binding(get: { target?.id }, set: { into = $0 })) {
                        ForEach(lib.library.profiles) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityLabel("Sidebar Profile to import bookmarks into")
                }
                Menu("Import Bookmarks") {
                    ForEach(sources) { src in
                        Button(src.label) { importBookmarks(src.file, named: "\(src.browser) Bookmarks") }
                    }
                    if !sources.isEmpty { Divider() }
                    Button("From a File…") { chooseFile() }
                }
                .fixedSize()
            }
            if let result {
                Text(result)
                    .font(DS.TextStyle.caption)
                    .foregroundStyle(failed ? DS.Palette.danger : DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Import")
        } footer: {
            Text("Read from files on this Mac; nothing is fetched. A bookmarks file is the bookmarks.html any browser exports.")
                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { sources = Self.findSources(model.browsers) }
        .onChange(of: model.browsers) { sources = Self.findSources(model.browsers) }
    }

    /// Every installed Chromium browser's profiles that have a Bookmarks file.
    static func findSources(_ browsers: [Browser]) -> [BookmarkSource] {
        browsers.filter { $0.family == .chromium }.flatMap { b -> [BookmarkSource] in
            guard let folder = b.dataFolder else { return [] }
            let root = support.appendingPathComponent(folder)
            guard let state = FileManager.default.contents(atPath: root.appendingPathComponent("Local State").path) else { return [] }
            return ProfileCatalog.parse(localStateJSON: state, browser: b.bundleId).profiles.compactMap { p in
                let file = root.appendingPathComponent(p.directory).appendingPathComponent("Bookmarks")
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                return BookmarkSource(browser: b.name, profile: p.name, file: file)
            }
        }
    }

    private func importArc(_ file: URL) {
        do {
            let spaces = try SidebarImport.arc(Self.read(file))
            let fresh = spaces.filter { !$0.isEmpty }
            guard !fresh.isEmpty else { return show("Arc has no Favorites or pinned tabs to import.", failed: true) }
            lib.change { $0.addProfiles(spaces) }
            if let problem = lib.problem { return show(problem, failed: true) }
            let links = fresh.reduce(0) { $0 + $1.linkCount }
            show("Imported \(count(links, "link")) from \(count(fresh.count, "Arc Space")) as \(fresh.count == 1 ? "a Sidebar Profile" : "Sidebar Profiles"). Pick one from the ⚙ at the top of the sidebar.", failed: false)
        } catch {
            show(Self.message(error), failed: true)
        }
    }

    private func importBookmarks(_ file: URL, named name: String) {
        guard let target else { return }
        do {
            let data = try Self.read(file)
            // A Chromium Bookmarks file is JSON; an export is HTML.
            let imported: ImportedSidebar
            if let chromium = try? SidebarImport.chromiumBookmarks(data) {
                imported = chromium
            } else if let text = String(data: data, encoding: .utf8), text.range(of: "<DT>", options: .caseInsensitive) != nil {
                imported = SidebarImport.bookmarksHTML(text)
            } else {
                throw SidebarImportError.notBookmarks
            }
            guard !imported.isEmpty else { return show("No bookmarks with a web address in that file.", failed: true) }
            lib.change(profile: target.id) { $0.add(imported, inFolder: name) }
            if let problem = lib.problem { return show(problem, failed: true) }
            show("Imported \(count(imported.linkCount, "bookmark")) into the folder \u{201C}\(name)\u{201D} in \(target.name).", failed: false)
        } catch {
            show(Self.message(error), failed: true)
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html, .json, .data]
        panel.prompt = "Import"
        panel.message = "Choose a bookmarks.html export, or a Browser Profile's Bookmarks file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Arc's own file is recognized too, so "From a File…" works for a copy of it.
        if url.lastPathComponent.hasPrefix("StorableSidebar") { importArc(url) } else { importBookmarks(url, named: "Bookmarks") }
    }

    /// Reads a file up to 64 MB: far more than any sidebar or bookmarks file.
    private static func read(_ file: URL) throws -> Data {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        guard size <= 64 << 20 else { throw SidebarImportError.notBookmarks }
        return try Data(contentsOf: file)
    }

    private static func message(_ error: Error) -> String {
        (error as? SidebarImportError)?.description ?? error.localizedDescription
    }

    private func count(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }

    private func show(_ text: String, failed: Bool) {
        result = text
        self.failed = failed
    }
}
