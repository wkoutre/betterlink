import Foundation

// What keeps sync from doing harm on its own (docs/sync.md, Safety): a hold
// when one push would delete many synced items at once, and a short history
// of what sync deleted or replaced on this Mac, so it can be put back. Both
// live in this Mac's settings folder (sync-local.json) and never sync.

/// When a push may not delete without asking first.
public enum SyncGuard {
    /// Deleting this many synced items at once always asks.
    public static let many = 5

    /// `deleting` items (counted by `SyncSafety.roots`: a folder or Sidebar
    /// Profile with what is inside it is one) out of `live` synced ones, from a settings folder
    /// that has (`fresh` false) or hasn't synced as this Mac before. A fresh
    /// one asks before deleting anything: its empty settings are far more
    /// likely a new folder than a choice. Otherwise five at once asks, and
    /// so do two or more that are over half of what there is.
    public static func trips(deleting: Int, live: Int, fresh: Bool) -> Bool {
        guard deleting > 0 else { return false }
        if fresh || deleting >= many { return true }
        return deleting >= 2 && deleting * 2 > live
    }
}

/// A push that was held back instead of deleting synced items.
public struct SyncHold: Codable, Equatable, Sendable {
    /// The entities it would mark deleted, sorted.
    public var ids: [String]
    /// How each is named, in the same order ("folder “Reading”").
    public var names: [String]
    /// This settings folder had never synced as this Mac.
    public var fresh: Bool
    public var since: Date

    public init(ids: [String], names: [String], fresh: Bool, since: Date) {
        self.ids = ids; self.names = names; self.fresh = fresh; self.since = since
    }

    /// What Sync settings and the CLI say.
    public var reason: String {
        let shown = names.prefix(6).joined(separator: ", ") + (names.count > 6 ? " and \(names.count - 6) more" : "")
        let count = ids.count == 1 ? "1 synced item" : "\(ids.count) synced items"
        let start = fresh ? "This settings folder hasn't synced on this Mac before, and it would delete \(count): "
                          : "This Mac would delete \(count) at once: "
        return start + shown + ". Sync is paused until you choose."
    }
}

/// The answer to a hold, for the push that comes next.
public struct SyncDecision: Codable, Equatable, Sendable {
    public enum Choice: String, Codable, Sendable {
        /// Delete them everywhere, once.
        case delete
        /// Keep them: take the shared ones back into this Mac's settings.
        case keep
    }
    public var choice: Choice
    /// The hold's ids it answers. A push that would delete anything else asks again.
    public var ids: [String]
    public init(choice: Choice, ids: [String]) { self.choice = choice; self.ids = ids }
}

/// Something sync deleted on this Mac, or a value another Mac's edit replaced.
public struct SyncHistoryEntry: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case deleted, changed }
    public var id: UUID
    public var date: Date
    /// One per sync, so a deleted folder or profile restores with what was deleted in it.
    public var batch: UUID
    public var entity: String
    public var kind: Kind
    /// The item, named ("Link Rule “github.com”").
    public var what: String
    /// The Mac whose edit it was.
    public var from: String
    /// What it held here before: every field for a delete, the replaced ones for a change.
    public var previous: [String: SyncValue]

    public init(id: UUID = UUID(), date: Date, batch: UUID, entity: String, kind: Kind, what: String, from: String,
                previous: [String: SyncValue]) {
        self.id = id; self.date = date; self.batch = batch; self.entity = entity; self.kind = kind
        self.what = what; self.from = from; self.previous = previous
    }

    /// One line for Sync settings and the CLI.
    public var summary: String {
        let name = what.prefix(1).uppercased() + what.dropFirst()
        switch kind {
        case .deleted: return "\(name) was deleted on \(from)."
        case .changed:
            let fields = Set(previous.keys.map(SyncSafety.fieldName)).sorted()
            return "\(name): \(fields.joined(separator: ", ")) changed on \(from)."
        }
    }
}

/// This Mac's own sync notes, in its settings folder. Never synced.
public struct SyncLocal: Codable, Equatable, Sendable {
    /// The device this settings folder last synced as. Missing or another
    /// one: the folder is new to sync here (SyncGuard's `fresh`).
    public var device: String?
    public var held: SyncHold?
    public var decision: SyncDecision?
    /// History entries to put back on the next sync.
    public var restore: [UUID] = []
    /// Newest first.
    public var history: [SyncHistoryEntry] = []

    public init() {}

    public static let historyLimit = 50
    public static let historyDays = 30

    /// Adds entries, newest first, keeping the last 50 and nothing older than 30 days.
    public mutating func record(_ entries: [SyncHistoryEntry], now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.historyDays) * 86_400)
        history = Array((entries + history).filter { $0.date >= cutoff }.prefix(Self.historyLimit))
    }
}

/// `<settings folder>/sync-local.json`, read and written under its own lock, so
/// the app's sync and the CLI never lose each other's changes.
public struct SyncLocalStore: Sendable {
    public let file: URL
    public init(folder: SettingsFolder) { file = folder.directory.appendingPathComponent("sync-local.json") }

    /// What is saved; empty when there is no file or it can't be read. An
    /// empty one only makes the next push more careful (it counts as fresh).
    public func load() -> SyncLocal {
        FileManager.default.contents(atPath: file.path).flatMap { try? JSONDecoder().decode(SyncLocal.self, from: $0) } ?? SyncLocal()
    }

    /// Changes it, starting from what is on disk now; writes only when something changed.
    @discardableResult
    public func update(_ change: (inout SyncLocal) throws -> Void) throws -> SyncLocal {
        try SettingsFile.withLock(beside: file, name: ".sync-local.lock", what: "sync-local.json") {
            let old = load()
            var new = old
            try change(&new)
            if new != old || !FileManager.default.fileExists(atPath: file.path) {
                try SettingsFile.write(new, to: file, what: "sync-local.json")
            }
            return new
        }
    }
}

public enum SyncSafety {
    /// Fields whose change alone isn't worth a history entry: a reorder.
    static let quiet: Set<String> = ["position", "deleted"]

    /// How an entity is named for a person.
    public static func describe(_ id: String, _ fields: [String: SyncValue]) -> String {
        func quoted(_ s: String?) -> String { s.map { " \u{201C}\($0)\u{201D}" } ?? "" }
        if id == SyncModel.globalID { return "global settings" }
        if id == SyncModel.configID { return "config.ts" }
        if id.hasPrefix("rule:") { return "Link Rule" + quoted(fields["pattern"]?.string) }
        if id.hasPrefix("mod:") { return "held-key rule" }
        if id.hasPrefix("sp:") { return "Sidebar Profile" + quoted(fields["name"]?.string) }
        if id.hasPrefix("node:") {
            let title = quoted(fields["title"]?.string ?? fields["url"]?.string)
            if fields["kind"]?.string == "folder" { return "folder" + title }
            return (fields["container"]?.string == "fav" ? "favorite" : "saved link") + title
        }
        return id
    }

    static func describe(_ id: String, in state: SyncState) -> String {
        describe(id, (state.entities[id] ?? [:]).mapValues(\.value))
    }

    /// A field's name in words.
    static func fieldName(_ k: String) -> String {
        switch k {
        case "title", "name": return "name"
        case "url": return "address"
        case "pattern": return "pattern"
        case "parent": return "folder"
        case "browser", "profile", "profileName", "profileAccount": return "profile"
        case "fallbackBrowser", "fallbackProfile", "fallbackName", "fallbackAccount": return "fallback"
        case "showLog": return "Show log"
        default: return k
        }
    }

    /// What a merge from `new` takes away from this Mac's `old` state, for
    /// the entities this Mac applies (`scope`): items deleted here, and
    /// values other Macs' edits replaced. `names` maps a device to its Mac's name.
    public static func changes(from old: SyncState, to new: SyncState, scope: (String) -> Bool, names: [String: String],
                               now: Date, batch: UUID = UUID()) -> [SyncHistoryEntry] {
        var out: [SyncHistoryEntry] = []
        for id in new.entities.keys.sorted() where id != SyncModel.configID && scope(id) && old.isLive(id) {
            guard let before = old.entities[id], let after = new.entities[id] else { continue }
            let what = describe(id, in: old)
            func who(_ s: HLC) -> String { names[s.device] ?? "another Mac" }
            if !new.isLive(id), let d = after["deleted"] {
                var previous = before.mapValues(\.value)
                previous["deleted"] = nil
                out.append(SyncHistoryEntry(date: now, batch: batch, entity: id, kind: .deleted, what: what, from: who(d.stamp), previous: previous))
                continue
            }
            var previous: [String: SyncValue] = [:], stamp: HLC?
            for (k, v) in after where !quiet.contains(k) {
                guard let was = before[k], v.stamp > was.stamp, v.value != was.value else { continue }
                previous[k] = was.value
                stamp = max(stamp ?? v.stamp, v.stamp)
            }
            if let stamp {
                out.append(SyncHistoryEntry(date: now, batch: batch, entity: id, kind: .changed, what: what, from: who(stamp), previous: previous))
            }
        }
        return out
    }

    /// The deletes that count toward SyncGuard: a deleted folder or Sidebar
    /// Profile counts once, with everything deleted inside it in the same
    /// push. So deleting a big folder on purpose doesn't ask.
    public static func roots(_ deleting: [String], in state: SyncState) -> [String] {
        let set = Set(deleting)
        // Deleting a folder deletes all of it, so the direct parent (or the
        // profile) being deleted too is enough.
        func inside(_ id: String) -> Bool {
            if let p = state.value(id, "profile")?.string, set.contains("sp:\(p)") { return true }
            if let parent = state.value(id, "parent")?.string, set.contains("node:\(parent)") { return true }
            return false
        }
        return deleting.filter { !inside($0) }
    }

    /// The kinds the empty-settings rule watches: Sidebar Profiles, and Link
    /// Rules with modifier rules.
    static let kinds: [(String) -> Bool] = [{ $0.hasPrefix("sp:") }, { $0.hasPrefix("rule:") || $0.hasPrefix("mod:") }]

    /// Whether a push would leave this Mac with none of a kind it shares 2
    /// or more of: every synced Sidebar Profile gone, or every rule. That is
    /// what an empty settings folder does (2026-11-25), whatever is counted,
    /// so it asks even when the folder has a starter sidebar.json. Deleting
    /// the only one of a kind follows the other rules.
    public static func wipesAKind(before: SyncState, after: SyncState, scope: (String) -> Bool) -> Bool {
        kinds.contains { kind in
            let had = before.entities.keys.filter { kind($0) && scope($0) && before.isLive($0) }
            return had.count >= 2 && !after.entities.keys.contains { kind($0) && scope($0) && after.isLive($0) }
        }
    }

    /// The entries to put back for `wanted`: each one, and for a deleted
    /// Sidebar Profile or folder, what was deleted in it by the same sync.
    public static func restoring(_ wanted: [UUID], from history: [SyncHistoryEntry]) -> [SyncHistoryEntry] {
        var picked = history.filter { wanted.contains($0.id) }
        var entities = Set(picked.filter { $0.kind == .deleted }.map(\.entity))
        let batches = Set(picked.map(\.batch))
        var grew = true
        while grew {
            grew = false
            for e in history where e.kind == .deleted && batches.contains(e.batch) && !entities.contains(e.entity) {
                let inProfile = e.previous["profile"]?.string.map { entities.contains("sp:\($0)") } ?? false
                let inFolder = e.previous["parent"]?.string.map { entities.contains("node:\($0)") } ?? false
                if inProfile || inFolder { picked.append(e); entities.insert(e.entity); grew = true }
            }
        }
        return picked
    }
}
