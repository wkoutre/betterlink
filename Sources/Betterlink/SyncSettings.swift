import AppKit
import BetterlinkCore
import SwiftUI

/// General › Sync: the folder, and what this Mac syncs (docs/sync.md).
struct SyncSettingsSection: View {
    @ObservedObject private var sync = SyncController.shared
    @ObservedObject private var lib = SidebarLibraryModel.shared

    var body: some View {
        DSSection {
            LabeledContent("Sync folder") {
                Text(sync.folder.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "Off")
                    .font(DS.TextStyle.code).foregroundStyle(DS.Palette.textSecondary).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: DS.Space.space2) {
                Text(sync.status).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary).lineLimit(2)
                Spacer()
                if sync.folder != nil { Button("Turn Off") { sync.turnOff() } }
                Button(sync.folder == nil ? "Choose Folder…" : "Change…") { chooseFolder() }
            }
            if sync.folder != nil {
                Toggle(isOn: $sync.selection.global) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Global settings")
                        Text("Link Rules, held-key rules, the fallback profile, Show log and config.ts.")
                            .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                ForEach(lib.library.profiles) { p in
                    profileRow(p.id, p.name)
                }
                ForEach(sync.offered, id: \.id) { o in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(o.name)
                            Text("Shared from another Mac").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                        }
                        Spacer()
                        Button("Add") { sync.add(o.id) }
                    }
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Pick a folder Dropbox, Google Drive or iCloud Drive keeps in sync. Each Mac writes only its own file there and reads the others', so edits made on two Macs at once both land; when both change the same thing, the later change wins and the Log says so. Which Sidebar Profile each Chrome profile shows stays on each Mac.")
                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func profileRow(_ id: UUID, _ name: String) -> some View {
        let on = Binding(get: { sync.selection.profiles[id] != nil },
                         set: { sync.selection.profiles[id] = $0 ? .init() : nil })
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sidebar Profile \u{201C}\(name)\u{201D}")
                    Text("Its favorites, folders and name.").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                }
            }
            if let parts = sync.selection.profiles[id] {
                HStack(spacing: DS.Space.space4) {
                    part("Favorites", parts.favorites) { sync.selection.profiles[id]?.favorites = $0 }
                    part("Folders", parts.folders) { sync.selection.profiles[id]?.folders = $0 }
                    part("Name", parts.appearance) { sync.selection.profiles[id]?.appearance = $0 }
                }
                .padding(.leading, DS.Space.space4)
            }
        }
    }

    private func part(_ label: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(label, isOn: Binding(get: { value }, set: set)).toggleStyle(.checkbox).font(DS.TextStyle.caption)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Sync Here"
        panel.message = "Pick a folder Dropbox, Google Drive or iCloud Drive keeps in sync."
        if panel.runModal() == .OK, let url = panel.url { sync.choose(folder: url) }
    }
}
