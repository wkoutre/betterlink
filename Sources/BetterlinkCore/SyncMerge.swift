import Foundation

// Making Sidebar Profiles that were made separately on different Macs one
// profile (docs/sync.md, Same-named profiles). Each Mac starts with its own
// "Primary", each with its own id, so sync sees them as different profiles.
// A merge keeps one of them, the survivor (the lowest id, so two Macs merging
// at once pick the same one), and marks each other one `mergedInto` it. Every
// Mac that syncs one of those then folds it into the survivor on its next
// sync: its saved links, its folders and which browser profiles show it. Nothing
// is deleted; only the merged profile's own entry goes.

/// A Sidebar Profile another Mac shares that this Mac hasn't added.
public struct SyncOffer: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// A Sidebar Profile on this Mac with the same name (ignoring case and
    /// spaces at the ends): what Merge would make it one with.
    public var sameNameAs: UUID?

    public init(id: UUID, name: String, sameNameAs: UUID? = nil) {
        self.id = id; self.name = name; self.sameNameAs = sameNameAs
    }
}

extension SyncModel {
    /// The field a merged Sidebar Profile carries: the profile it is part of now.
    static let mergedIntoField = "mergedInto"

    /// The profile `id` is part of now: itself, unless it was merged into
    /// another (following merges of merges).
    public static func mergeTarget(_ id: UUID, in state: SyncState) -> UUID {
        var cur = id, seen: Set<UUID> = [id]
        while let next = state.value(profileID(cur), mergedIntoField)?.string.flatMap(UUID.init(uuidString:)),
              !seen.contains(next) {
            seen.insert(next); cur = next
        }
        return cur
    }

    public static func sameName(_ a: String, _ b: String) -> Bool {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        return !t(a).isEmpty && t(a) == t(b)
    }

    /// The Sidebar Profiles other Macs share that aren't in this Mac's
    /// selection or library, for Sync settings' Add (and Merge, when one here
    /// has the same name) and `betterlink sync get`.
    public static func offers(state: SyncState, selected: Set<UUID>, library: SidebarLibrary) -> [SyncOffer] {
        let here = Set(library.profiles.map(\.id))
        return state.entities.keys.filter { $0.hasPrefix("sp:") && state.isLive($0) }
            .compactMap { k -> SyncOffer? in
                guard let u = uuid(k), !selected.contains(u), !here.contains(u), mergeTarget(u, in: state) == u else { return nil }
                let name = state.value(k, "name")?.string ?? "Sidebar Profile"
                let match = library.profiles.first { sameName($0.name, name) }?.id
                return SyncOffer(id: u, name: name, sameNameAs: match)
            }
            .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
    }

    /// The profiles a Merge of `id` (an offer, or a profile here) makes one:
    /// it, this Mac's profile with its name, and every other offer with that name.
    public static func mergeGroup(_ id: UUID, state: SyncState, selected: Set<UUID>, library: SidebarLibrary) -> [UUID] {
        let name = library.profiles.first { $0.id == id }?.name ?? state.value(profileID(id), "name")?.string
        guard let name else { return [] }
        let local = library.profiles.filter { sameName($0.name, name) }.map(\.id)
        let offered = offers(state: state, selected: selected, library: library).filter { sameName($0.name, name) }.map(\.id)
        let group = Set([id] + local + offered)
        return group.count > 1 ? group.sorted { $0.uuidString < $1.uuidString } : []
    }

    /// Carries out a Merge asked for on this Mac: marks every profile in
    /// `group` but the survivor merged into it (stamped now, so it wins on
    /// every Mac), and moves their synced saved links and folders into it,
    /// after its own. The survivor syncs everything from here on. Returns the
    /// survivor; nil when fewer than two of `group` exist.
    @discardableResult
    public static func requestMerge(_ group: [UUID], state: inout SyncState, library: SidebarLibrary,
                                    selection: inout SyncSelection, clock: inout HLCClock, now: Int64) -> UUID? {
        let here = Set(library.profiles.map(\.id))
        let members = Set(group.map { mergeTarget($0, in: state) })
            .filter { here.contains($0) || state.isLive(profileID($0)) }
            .sorted { $0.uuidString < $1.uuidString }
        guard members.count > 1, let survivor = members.first else { return nil }
        func stamp(_ id: String, _ k: String, _ v: SyncValue) {
            if state.entities[id]?[k]?.value == v { return }
            state.entities[id, default: [:]][k] = Stamped(v, clock.tick(now: now))
        }
        // The survivor syncs all of each member: Merge is asked for to share them.
        var parts = SyncSelection.Parts(favorites: false, folders: false, appearance: false)
        for m in members {
            let p = selection.profiles[m] ?? .init()
            parts.favorites = parts.favorites || p.favorites
            parts.folders = parts.folders || p.folders
            parts.appearance = parts.appearance || p.appearance
        }
        selection.profiles[survivor] = parts
        // The others' top-level items go after the survivor's, in order.
        func top(_ container: String, _ profile: UUID) -> [(String, String)] {
            state.entities.compactMap { k, f -> (String, String)? in
                guard k.hasPrefix("node:"), state.isLive(k), f["container"]?.value.string == container,
                      f["parent"]?.value.string == nil,
                      f["profile"]?.value.string.flatMap(UUID.init(uuidString:)) == profile,
                      let pos = f["position"]?.value.string else { return nil }
                return (k, pos)
            }.sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        }
        // The survivor's last top-level position: in the state, or where the
        // next push will put what this Mac has of it that sync hasn't seen
        // (the same positions `project` gives them).
        var last: [String: String?] = [:]
        let mine = library.profiles.first { $0.id == survivor }
        for c in ["fav", "items"] {
            let ids = (c == "fav" ? mine?.favorites.map(\.id) : mine?.items.map(\.id))?.map(nodeID) ?? []
            let existing = Dictionary(uniqueKeysWithValues: ids.compactMap { id in state.value(id, "position")?.string.map { (id, $0) } })
            let local = FractionalIndex.positions(for: ids, existing: existing).values
            last[c] = .some(([top(c, survivor).last?.1].compactMap { $0 } + local).max())
        }
        for x in members.dropFirst() {
            for c in ["fav", "items"] {
                for (k, _) in top(c, x) {
                    let p = FractionalIndex.between(last[c] ?? nil, nil)
                    stamp(k, "position", .string(p))
                    last[c] = .some(p)
                }
            }
            for (k, f) in state.entities where k.hasPrefix("node:") && f["profile"]?.value.string == x.uuidString {
                stamp(k, "profile", .string(survivor.uuidString))
            }
            stamp(profileID(x), mergedIntoField, .string(survivor.uuidString))
            if state.entities[profileID(x)]?["deleted"]?.value != .bool(true) { stamp(profileID(x), "deleted", .bool(true)) }
            selection.profiles[x] = nil
        }
        return survivor
    }

    /// Folds each Sidebar Profile here that was merged into another (on any
    /// Mac) into that one, when this Mac syncs it or asked for the merge
    /// (`requested`): its saved links and folders go after the survivor's,
    /// its browser profiles show the survivor, and the survivor syncs what it
    /// synced. A survivor this Mac doesn't have yet takes the merged one's
    /// place, keeping everything in it. Profiles this Mac keeps to itself are
    /// left alone.
    public static func followMerges(_ state: SyncState, library: SidebarLibrary, selection: SyncSelection,
                                    requested: Set<UUID> = []) -> (library: SidebarLibrary, selection: SyncSelection) {
        var lib = library, sel = selection
        func union(_ a: SyncSelection.Parts?, _ b: SyncSelection.Parts) -> SyncSelection.Parts {
            guard let a else { return b }
            return .init(favorites: a.favorites || b.favorites, folders: a.folders || b.folders, appearance: a.appearance || b.appearance)
        }
        for p in library.profiles {
            let t = mergeTarget(p.id, in: state)
            guard t != p.id, sel.profiles[p.id] != nil || requested.contains(p.id),
                  let i = lib.profiles.firstIndex(where: { $0.id == p.id }) else { continue }
            let parts = sel.profiles[p.id] ?? .init()
            sel.profiles[p.id] = nil
            sel.profiles[t] = union(sel.profiles[t], parts)
            if let j = lib.profiles.firstIndex(where: { $0.id == t }) {
                // Only one profile shows every unlinked browser profile.
                let otherCatchAll = lib.profiles.contains { $0.id != p.id && $0.id != t && $0.browserProfiles.isEmpty }
                lib.profiles[j].fold(lib.profiles[i], catchAll: !otherCatchAll)
                lib.profiles.remove(at: i)
            } else {
                lib.profiles[i].id = t
            }
        }
        // A merged profile this Mac selected but doesn't have: its selection moves on.
        for (id, parts) in sel.profiles {
            let t = mergeTarget(id, in: state)
            if t != id { sel.profiles[id] = nil; sel.profiles[t] = union(sel.profiles[t], parts) }
        }
        return (lib, sel)
    }
}

extension SidebarProfile {
    /// Takes in another profile: its favorites and items that aren't here
    /// already (by id) go after this one's, and its browser profiles show this
    /// one. When either showed every browser profile not linked to another
    /// (no links), this one does, unless `catchAll` is false (another
    /// profile already does).
    mutating func fold(_ other: SidebarProfile, catchAll: Bool = true) {
        let mine = allLinks.map(\.id) + SidebarProfile.allFolders(in: items).map(\.id)
        var have = Set(mine)
        for f in other.favorites where !have.contains(f.id) { favorites.append(f); have.insert(f.id) }
        for item in other.items where !have.contains(item.id) { items.append(item); have.insert(item.id) }
        if catchAll, browserProfiles.isEmpty || other.browserProfiles.isEmpty { browserProfiles = [] }
        else { for r in other.browserProfiles where !browserProfiles.contains(r) { browserProfiles.append(r) } }
    }
}
