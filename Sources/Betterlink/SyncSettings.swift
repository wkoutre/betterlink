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
                Button(sync.folder == nil ? "Choose Folder…" : "Change…") { sync.chooseFolderWithPanel() }
            }
            if sync.folder != nil {
                // Each other Mac, and when it last synced; one quiet for a week is flagged.
                ForEach(sync.peers) { peer in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(peer.summary(now: Date())).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textSecondary)
                        if let warning = peer.warning(now: Date()) {
                            Label("\(peer.name) \(warning).", systemImage: "exclamationmark.triangle.fill")
                                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if sync.folder != nil, let held = sync.held {
                VStack(alignment: .leading, spacing: DS.Space.space2) {
                    Text(held.reason).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DS.Space.space2) {
                        Spacer()
                        Button("Keep Them") { sync.resolveHold(.keep) }
                            .help("Take the synced items back into this Mac's settings. Nothing is deleted.")
                        Button("Delete Them Everywhere", role: .destructive) { sync.resolveHold(.delete) }
                            .help("Delete these items on every Mac, this once.")
                    }
                }
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
                ForEach(sync.offered) { o in offerRow(o) }
                if !sync.history.isEmpty { recentlyChanged }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Pick a folder Dropbox, Google Drive or iCloud Drive keeps in sync. Each Mac writes only its own file there and reads the others', so edits made on two Macs at once both land; when both change the same thing, the later change wins and the Log says so. Which Sidebar Profile each Chrome profile shows stays on each Mac.")
                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What sync deleted here or replaced with another Mac's edit (this Mac
    /// only, the last 50 over 30 days), each with Restore.
    private var recentlyChanged: some View {
        VStack(alignment: .leading, spacing: DS.Space.space2) {
            Text("Recently changed by sync")
            Text("Restore puts the earlier value back as a new edit on this Mac, so it wins on every Mac.")
                .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(sync.history.prefix(10)) { entry in
                HStack(spacing: DS.Space.space2) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.summary).lineLimit(2)
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    }
                    Spacer()
                    if sync.restoring.contains(entry.id) {
                        Text("Restoring").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    } else {
                        Button("Restore") { sync.restore(entry) }
                    }
                }
            }
            if sync.history.count > 10 {
                Text("\(sync.history.count - 10) more: betterlink sync history")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ id: UUID, _ name: String) -> some View {
        let on = Binding(get: { sync.selection.profiles[id] != nil },
                         set: { sync.selection.profiles[id] = $0 ? .init() : nil })
        let parts = sync.selection.profiles[id]
        VStack(alignment: .leading, spacing: DS.Space.space2) {
            Toggle(isOn: on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sidebar Profile \u{201C}\(name.trimmingCharacters(in: .whitespaces))\u{201D}")
                    Text(summary(parts)).font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                }
            }
            if let parts {
                HStack(spacing: DS.Space.space2) {
                    SyncPartChip(label: "Favorites", symbol: "star", isOn: parts.favorites) { sync.selection.profiles[id]?.favorites.toggle() }
                    SyncPartChip(label: "Folders", symbol: "folder", isOn: parts.folders) { sync.selection.profiles[id]?.folders.toggle() }
                    SyncPartChip(label: "Name", symbol: "textformat", isOn: parts.appearance) { sync.selection.profiles[id]?.appearance.toggle() }
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: parts != nil)
    }

    /// A Sidebar Profile another Mac shares. One with the same name as a
    /// profile here (each Mac starts with its own "Primary") offers Merge,
    /// which makes them one profile on every Mac; Add keeps them apart.
    @ViewBuilder
    private func offerRow(_ o: SyncOffer) -> some View {
        let name = o.name.trimmingCharacters(in: .whitespaces)
        HStack(spacing: DS.Space.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sidebar Profile \u{201C}\(name)\u{201D}")
                Text(o.sameNameAs == nil ? "Shared from another Mac."
                     : "Shared from another Mac, and this Mac has one with the same name. Merge makes them one profile on every Mac, with the favorites and folders of both.")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if sync.pendingOffers.contains(o.id) {
                Text("Adding").font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
            } else if o.sameNameAs != nil, !sync.mergeWaitsFor.isEmpty {
                Button("Add Separately") { sync.add(o) }
                Text("Merge needs the latest betterlink on \(sync.mergeWaitsFor.joined(separator: ", ")).")
                    .font(DS.TextStyle.caption).foregroundStyle(DS.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if o.sameNameAs != nil {
                Button("Add Separately") { sync.add(o) }
                    .help("Add it as a second profile named \u{201C}\(name)\u{201D}.")
                Button("Merge") { sync.merge(o) }
                    .buttonStyle(.dsPrimary)
                    .help("Make it and this Mac's \u{201C}\(name)\u{201D} one Sidebar Profile on every Mac. Nothing in either is deleted.")
            } else {
                Button("Add") { sync.add(o) }
            }
        }
    }

    /// What this profile's switch covers now, in words.
    private func summary(_ parts: SyncSelection.Parts?) -> String {
        guard let parts else { return "Stays on this Mac." }
        let names = [parts.favorites ? "favorites" : nil, parts.folders ? "folders" : nil, parts.appearance ? "name" : nil].compactMap { $0 }
        switch names.count {
        case 0: return "Pick what syncs below."
        case 1: return "Syncs its \(names[0])."
        default: return "Syncs its \(names.dropLast().joined(separator: ", ")) and \(names.last!)."
        }
    }
}

/// One part of a Sidebar Profile that can sync, as a pill: filled with a
/// check when it syncs, outlined when it doesn't.
private struct SyncPartChip: View {
    let label: String
    let symbol: String
    let isOn: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 12)
                Text(label).font(DS.TextStyle.caption)
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .foregroundStyle(isOn ? DS.Palette.accentText : DS.Palette.textSecondary)
            .background(Capsule().fill(isOn ? DS.Palette.accentTint : (hovering ? DS.Palette.hover : Color.clear)))
            .overlay(Capsule().strokeBorder(isOn ? DS.Palette.accent.opacity(0.35) : DS.Palette.border, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isOn)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "Syncs" : "Doesn't sync")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(isOn ? "\(label) syncs. Click to keep it on this Mac." : "\(label) stays on this Mac. Click to sync it.")
    }
}
