import Foundation

// Turning betterlink's settings into synced entities and back (docs/sync.md).
// Everything here is plain values in, plain values out, so the property tests
// can run many simulated Macs without files or a UI.

/// What this Mac syncs (Settings › Sync). Per Mac; never synced itself.
public struct SyncSelection: Codable, Equatable, Sendable {
    public struct Parts: Codable, Equatable, Sendable {
        public var favorites = true
        public var folders = true
        public var appearance = true
        public init(favorites: Bool = true, folders: Bool = true, appearance: Bool = true) {
            self.favorites = favorites; self.folders = folders; self.appearance = appearance
        }
    }
    /// Link Rules, modifier rules, the fallback and Show log.
    public var global: Bool
    /// The Sidebar Profiles that sync, and which of their parts.
    public var profiles: [UUID: Parts]

    public init(global: Bool = true, profiles: [UUID: Parts] = [:]) {
        self.global = global; self.profiles = profiles
    }
}

/// How a browser profile is named on this Mac, so a rule can find the same
/// profile on another Mac: by its signed-in account first, then its name.
public struct ProfileIdentity: Equatable, Sendable {
    public var name: String?
    public var account: String?
    public init(name: String?, account: String?) { self.name = name; self.account = account }
}

public enum SyncModel {
    // MARK: Ids

    static func ruleID(_ id: UUID) -> String { "rule:\(id.uuidString)" }
    static func modID(_ id: UUID) -> String { "mod:\(id.uuidString)" }
    static func profileID(_ id: UUID) -> String { "sp:\(id.uuidString)" }
    static func nodeID(_ id: UUID) -> String { "node:\(id.uuidString)" }
    static let globalID = "global"
    static let configID = "config"

    static func uuid(_ entity: String) -> UUID? {
        entity.split(separator: ":", maxSplits: 1).last.flatMap { UUID(uuidString: String($0)) }
    }

    // MARK: Local → entities

    /// The entities this Mac's settings say should exist, with their field
    /// values. Positions keep the ones already in `state` where the order
    /// still agrees, so a sync never renumbers a whole list.
    ///
    /// `applied` is the browser profile this Mac last put in place for each
    /// synced target (materialize's `applied`). A local target still equal to
    /// it is the synced one, translated to this Mac's folder names, so the
    /// synced fields go out unchanged: a Mac never pushes its own folder name
    /// over another Mac's for the same profile. A target that differs was
    /// edited here and goes out with this Mac's identity of it.
    public static func project(rules: RuleStore.Contents, library: SidebarLibrary, selection: SyncSelection,
                               identity: (ProfileRef) -> ProfileIdentity, state: SyncState,
                               applied: [String: ProfileRef] = [:]) -> [String: [String: SyncValue]] {
        var out: [String: [String: SyncValue]] = [:]
        func existing(_ ids: [String]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: ids.compactMap { id in state.value(id, "position")?.string.map { (id, $0) } })
        }
        /// The four fields naming a target: the synced ones when this Mac
        /// hasn't changed what sync applied, else this Mac's own.
        func target(_ id: String, _ local: ProfileRef?, _ k: TargetKeys) -> [String: SyncValue] {
            if applied[id] == (local ?? noProfile), state.value(id, k.browser) != nil {
                return [k.browser: state.value(id, k.browser) ?? .null, k.directory: state.value(id, k.directory) ?? .null,
                        k.name: state.value(id, k.name) ?? .null, k.account: state.value(id, k.account) ?? .null]
            }
            let who = local.map(identity)
            return [k.browser: .of(local?.browser), k.directory: .of(local?.directory), k.name: .of(who?.name), k.account: .of(who?.account)]
        }
        if selection.global {
            let ids = rules.rules.map { ruleID($0.id) }
            let pos = FractionalIndex.positions(for: ids, existing: existing(ids))
            for r in rules.rules {
                let id = ruleID(r.id)
                out[id] = target(id, r.target, .rule).merging(["kind": .string(r.kind.rawValue), "pattern": .string(r.pattern),
                                                               "position": .string(pos[id]!)]) { a, _ in a }
                // A rule that never had backups sends no field, so its entity reads as it did before backups.
                if !r.backups.isEmpty || (state.value(id, "backups") ?? .null) != .null {
                    out[id]!["backups"] = backupsField(id, r.backups, state: state, applied: applied, identity: identity)
                }
            }
            let mods = rules.modifierRules ?? []
            let mids = mods.map { modID($0.id) }
            let mpos = FractionalIndex.positions(for: mids, existing: existing(mids))
            for m in mods {
                let id = modID(m.id)
                out[id] = target(id, m.target, .rule).merging(["keys": .number(Double(m.keys.rawValue)),
                                                               "position": .string(mpos[id]!)]) { a, _ in a }
            }
            out[globalID] = target(globalID, rules.fallback, .fallback)
                .merging(["showLog": rules.showLog.map { .bool($0) } ?? .null]) { a, _ in a }
        }
        for p in library.profiles {
            guard let parts = selection.profiles[p.id] else { continue }
            if parts.appearance { out[profileID(p.id)] = ["name": .string(p.name)] }
            else { out[profileID(p.id)] = [:] }
            if parts.favorites {
                let ids = p.favorites.map { nodeID($0.id) }
                let pos = FractionalIndex.positions(for: ids, existing: existing(ids))
                for l in p.favorites { out[nodeID(l.id)] = linkFields(l, profile: p.id, container: "fav", parent: nil, position: pos[nodeID(l.id)]!) }
            }
            if parts.folders {
                func walk(_ items: [SidebarItem], parent: UUID?) {
                    let ids = items.map { nodeID($0.id) }
                    let pos = FractionalIndex.positions(for: ids, existing: existing(ids))
                    for item in items {
                        switch item {
                        case .link(let l):
                            out[nodeID(l.id)] = linkFields(l, profile: p.id, container: "items", parent: parent, position: pos[nodeID(l.id)]!)
                        case .folder(let f):
                            let id = nodeID(f.id)
                            out[id] = ["kind": .string("folder"), "profile": .string(p.id.uuidString), "container": .string("items"),
                                       "parent": .of(parent?.uuidString), "position": .string(pos[id]!), "title": .string(f.name)]
                            // "No icon" goes out only for an icon removed on this Mac
                            // (iconRemoved), and only when the state still has one. A folder
                            // that merely has none sends no field: a Mac that has just updated
                            // from a betterlink without icons has none on every folder, and
                            // must not stamp "no icon" over one another Mac set (review F1).
                            if let icon = f.icon { out[id]!["icon"] = .string(icon.raw) }
                            else if f.iconRemoved == true, let had = state.value(id, "icon"), had != .null { out[id]!["icon"] = .null }
                            walk(f.items, parent: f.id)
                        }
                    }
                }
                walk(p.items, parent: nil)
            }
        }
        return out
    }

    /// `applied` for "no profile": a synced fallback this Mac couldn't match
    /// while it had none of its own.
    static let noProfile = ProfileRef(browser: "", directory: "")

    /// A rule's backup profile as it syncs: like a rule's own target, the
    /// browser and folder plus the name and account that find it on another Mac.
    struct SyncedTarget: Codable, Equatable {
        var browser: String
        var profile: String
        var profileName: String?
        var profileAccount: String?
    }

    /// `applied` for a rule's backup, counted from 1.
    static func backupKey(_ id: String, _ n: Int) -> String { "\(id)#\(n)" }

    static func syncedBackups(_ v: SyncValue?) -> [SyncedTarget] {
        guard let s = v?.string, let d = s.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([SyncedTarget].self, from: d)) ?? []
    }

    /// The "backups" field: a JSON list. Each backup still equal to the
    /// profile sync put in place for one of the synced backups goes out as
    /// that synced entry, unchanged (as `target` does for the first choice),
    /// so a Mac without a profile never erases what another Mac knows about it.
    static func backupsField(_ id: String, _ backups: [ProfileRef], state: SyncState, applied: [String: ProfileRef],
                             identity: (ProfileRef) -> ProfileIdentity) -> SyncValue {
        guard !backups.isEmpty else { return .null }
        let synced = syncedBackups(state.value(id, "backups"))
        var used = Set<Int>()
        let list = backups.map { ref -> SyncedTarget in
            if let j = synced.indices.first(where: { !used.contains($0) && applied[backupKey(id, $0 + 1)] == ref }) {
                used.insert(j)
                return synced[j]
            }
            let who = identity(ref)
            return SyncedTarget(browser: ref.browser, profile: ref.directory, profileName: who.name, profileAccount: who.account)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(list)).flatMap { String(data: $0, encoding: .utf8) }.map(SyncValue.string) ?? .null
    }

    struct TargetKeys {
        let browser, directory, name, account: String
        static let rule = TargetKeys(browser: "browser", directory: "profile", name: "profileName", account: "profileAccount")
        static let fallback = TargetKeys(browser: "fallbackBrowser", directory: "fallbackProfile", name: "fallbackName", account: "fallbackAccount")
    }

    static func linkFields(_ l: SavedLink, profile: UUID, container: String, parent: UUID?, position: String) -> [String: SyncValue] {
        ["kind": .string("link"), "profile": .string(profile.uuidString), "container": .string(container),
         "parent": .of(parent?.uuidString), "position": .string(position), "title": .string(l.title), "url": .string(l.url), "icon": .of(l.icon)]
    }

    /// Which entities this Mac speaks for, so an entity it doesn't have is
    /// marked deleted only when it is in this Mac's selection.
    public static func scope(_ selection: SyncSelection, state: SyncState) -> (String) -> Bool {
        { id in
            if id == globalID || id == configID || id.hasPrefix("rule:") || id.hasPrefix("mod:") { return selection.global }
            if id.hasPrefix("sp:") { return uuid(id).flatMap { selection.profiles[$0] } != nil }
            if id.hasPrefix("node:") {
                // A node of a merged profile belongs to the profile it was merged into.
                guard let p = state.value(id, "profile")?.string.flatMap(UUID.init(uuidString:)),
                      let parts = selection.profiles[mergeTarget(p, in: state)] else { return false }
                return state.value(id, "container")?.string == "fav" ? parts.favorites : parts.folders
            }
            return false
        }
    }

    // MARK: Entities → local

    /// What a merge changed on this Mac that wasn't its own choice, for the Log.
    public struct Notes: Equatable, Sendable {
        public var unresolvedRules: [UUID] = []
        /// For each of those, the profile it was made for on another Mac
        /// (its name there, else its account or folder), to show beside it.
        public var missingProfiles: [UUID: String] = [:]
        public var orphansMovedToTop: [UUID] = []
        public var cyclesBroken: [UUID] = []
    }

    /// This Mac's settings rebuilt from the merged state, for everything in
    /// the selection; everything else stays as it is locally. `resolve` finds
    /// a browser profile on this Mac from another Mac's (account, then name).
    /// A rule whose profile this Mac doesn't have opens in this Mac's
    /// fallback (the same browser's Default profile when none is set), never
    /// in whatever profile happens to share the other Mac's folder name.
    /// `applied` says which local profile each synced target became, for
    /// `project`.
    public static func materialize(_ state: SyncState, rules local: RuleStore.Contents, library: SidebarLibrary,
                                   selection: SyncSelection,
                                   resolve: (_ browser: String, _ directory: String, ProfileIdentity) -> String?)
    -> (rules: RuleStore.Contents, library: SidebarLibrary, notes: Notes, applied: [String: ProfileRef]) {
        var notes = Notes()
        var applied: [String: ProfileRef] = [:]
        var rules = local
        func live(_ prefix: String) -> [(String, [String: Stamped])] {
            state.entities.filter { $0.key.hasPrefix(prefix) && state.isLive($0.key) }
                .sorted { a, b in
                    let pa = a.value["position"]?.value.string ?? "", pb = b.value["position"]?.value.string ?? ""
                    return pa != pb ? pa < pb : a.key < b.key
                }
        }
        /// The local profile for a synced target, or nil when this Mac has none.
        func resolved(_ id: String, _ k: TargetKeys) -> ProfileRef? {
            guard let browser = state.value(id, k.browser)?.string, let dir = state.value(id, k.directory)?.string else { return nil }
            let who = ProfileIdentity(name: state.value(id, k.name)?.string, account: state.value(id, k.account)?.string)
            return resolve(browser, dir, who).map { ProfileRef(browser: browser, directory: $0) }
        }
        if selection.global {
            // The fallback first: unmatched rules open there.
            if let g = state.entities[globalID] {
                if g["fallbackBrowser"]?.value.string != nil {
                    // A fallback profile this Mac doesn't have keeps this Mac's own.
                    if let ref = resolved(globalID, .fallback) { rules.fallback = ref }
                    applied[globalID] = rules.fallback ?? noProfile
                } else if g["fallbackBrowser"] != nil {
                    rules.fallback = nil
                }
                if let v = g["showLog"]?.value { rules.showLog = v.bool }
            }
            func place(_ id: String) -> ProfileRef? {
                guard let browser = state.value(id, "browser")?.string else { return nil }
                if let ref = resolved(id, .rule) { applied[id] = ref; return ref }
                let ref = rules.fallback ?? ProfileRef(browser: browser, directory: "Default")
                applied[id] = ref
                return nil
            }
            rules.rules = live("rule:").compactMap { id, f in
                guard let u = uuid(id), let kind = f["kind"]?.value.string.flatMap(Rule.Kind.init(rawValue:)),
                      let pattern = f["pattern"]?.value.string, let browser = f["browser"]?.value.string else { return nil }
                let synced = syncedBackups(f["backups"]?.value)
                if !synced.isEmpty {
                    // A profile this Mac doesn't have keeps its browser with no
                    // folder, which never opens: the next profile gets the link.
                    func here(_ key: String, _ b: String, _ dir: String, _ who: ProfileIdentity) -> ProfileRef {
                        let ref = resolve(b, dir, who).map { ProfileRef(browser: b, directory: $0) } ?? ProfileRef(browser: b, directory: "")
                        applied[key] = ref
                        return ref
                    }
                    let first = here(id, browser, state.value(id, "profile")?.string ?? "",
                                     ProfileIdentity(name: state.value(id, "profileName")?.string, account: state.value(id, "profileAccount")?.string))
                    let backups = synced.enumerated().map { j, t in
                        here(backupKey(id, j + 1), t.browser, t.profile, ProfileIdentity(name: t.profileName, account: t.profileAccount))
                    }
                    if ([first] + backups).allSatisfy({ $0.directory.isEmpty && Browser.known(bundleId: $0.browser)?.family != .plain }) {
                        notes.unresolvedRules.append(u)
                        let wanted = [state.value(id, TargetKeys.rule.name)?.string, state.value(id, TargetKeys.rule.account)?.string,
                                      state.value(id, TargetKeys.rule.directory)?.string].compactMap { $0 }.first { !$0.isEmpty }
                        if let wanted { notes.missingProfiles[u] = wanted }
                    }
                    return Rule(id: u, kind: kind, pattern: pattern, browser: first.browser, profile: first.directory, backups: backups)
                }
                if place(id) == nil {
                    notes.unresolvedRules.append(u)
                    let wanted = [state.value(id, TargetKeys.rule.name)?.string, state.value(id, TargetKeys.rule.account)?.string,
                                  state.value(id, TargetKeys.rule.directory)?.string].compactMap { $0 }.first { !$0.isEmpty }
                    if let wanted { notes.missingProfiles[u] = wanted }
                }
                let ref = applied[id]!
                return Rule(id: u, kind: kind, pattern: pattern, browser: ref.browser, profile: ref.directory)
            }
            let mods: [ModifierRule] = live("mod:").compactMap { id, f in
                guard let u = uuid(id), let k = f["keys"]?.value.number, f["browser"]?.value.string != nil else { return nil }
                _ = place(id)
                let ref = applied[id]!
                return ModifierRule(id: u, keys: ModifierKeys(rawValue: Int(k)), browser: ref.browser, profile: ref.directory)
            }
            rules.modifierRules = mods.isEmpty && local.modifierRules == nil ? nil : mods
        }

        var lib = library
        for (pid, parts) in selection.profiles.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            let sid = profileID(pid)
            guard state.entities[sid] != nil, mergeTarget(pid, in: state) == pid else { continue }
            if !state.isLive(sid) { lib.profiles.removeAll { $0.id == pid }; continue }
            var p = lib.profiles.first { $0.id == pid } ?? SidebarProfile(id: pid, name: "Profile")
            if parts.appearance, let n = state.value(sid, "name")?.string { p.name = n }
            // Its own nodes, and those of any profile merged into it whose
            // move hasn't reached this Mac yet.
            let nodes = state.entities.filter { k, f in
                k.hasPrefix("node:") && state.isLive(k)
                    && f["profile"]?.value.string.flatMap(UUID.init(uuidString:)).map { mergeTarget($0, in: state) } == pid
            }
            if parts.favorites {
                p.favorites = nodes.filter { $0.value["container"]?.value.string == "fav" && $0.value["kind"]?.value.string == "link" }
                    .sorted { ($0.value["position"]?.value.string ?? "", $0.key) < ($1.value["position"]?.value.string ?? "", $1.key) }
                    .compactMap { k, f in link(k, f) }
            }
            if parts.folders {
                let local = SidebarProfile.allFolders(in: p.items)
                let expanded = Dictionary(local.map { ($0.id, $0.expanded) }, uniquingKeysWith: { a, _ in a })
                let icons = Dictionary(local.compactMap { f in f.icon.map { (f.id, $0) } }, uniquingKeysWith: { a, _ in a })
                p.items = tree(nodes.filter { $0.value["container"]?.value.string == "items" }, expanded: expanded, icons: icons, notes: &notes)
            }
            if let i = lib.profiles.firstIndex(where: { $0.id == pid }) { lib.profiles[i] = p } else { lib.profiles.append(p) }
        }
        return (rules, lib, notes, applied)
    }

    static func link(_ key: String, _ f: [String: Stamped]) -> SavedLink? {
        guard let u = uuid(key), let url = f["url"]?.value.string else { return nil }
        return SavedLink(id: u, title: f["title"]?.value.string ?? url, url: url, icon: f["icon"]?.value.string)
    }

    /// Folders and links from flat nodes: a missing or deleted parent puts a
    /// node at the top level (nothing lost); parent loops are broken the same
    /// way on every Mac, lowest id first.
    ///
    /// A folder's icon is the synced one. A folder whose synced fields have no
    /// icon at all (written before folder icons, or by a Mac without them)
    /// keeps this Mac's (`icons`), which goes out with the next push. A
    /// removal this Mac made was pushed before this runs, so its mark
    /// (`iconRemoved`) is not carried over.
    static func tree(_ nodes: [String: [String: Stamped]], expanded: [UUID: Bool], icons: [UUID: FolderIcon] = [:],
                     notes: inout Notes) -> [SidebarItem] {
        var parent: [UUID: UUID?] = [:]
        var fields: [UUID: [String: Stamped]] = [:]
        for (k, f) in nodes { if let u = uuid(k) { fields[u] = f } }
        let folders = Set(fields.filter { $0.value["kind"]?.value.string == "folder" }.keys)
        for (u, f) in fields {
            let p = f["parent"]?.value.string.flatMap(UUID.init(uuidString:))
            if let p, !folders.contains(p) { notes.orphansMovedToTop.append(u); parent[u] = .some(nil) }
            else { parent[u] = .some(p) }
        }
        // Break cycles: follow each folder's chain; a chain that returns to a
        // folder already on it is cut at its lowest id.
        for start in folders.sorted(by: { $0.uuidString < $1.uuidString }) {
            var seen: [UUID] = [], cur: UUID? = start
            while let c = cur, !seen.contains(c) { seen.append(c); cur = parent[c] ?? nil }
            if let c = cur, let i = seen.firstIndex(of: c) {
                let loop = seen[i...]
                let cut = loop.min { $0.uuidString < $1.uuidString }!
                parent[cut] = .some(nil)
                notes.cyclesBroken.append(cut)
            }
        }
        func children(of p: UUID?) -> [SidebarItem] {
            fields.filter { (parent[$0.key] ?? nil) == p }
                .sorted { ($0.value["position"]?.value.string ?? "", $0.key.uuidString) < ($1.value["position"]?.value.string ?? "", $1.key.uuidString) }
                .compactMap { u, f -> SidebarItem? in
                    if f["kind"]?.value.string == "folder" {
                        let icon: FolderIcon? = f["icon"].map { $0.value.string.map(FolderIcon.init(raw:)) } ?? icons[u]
                        return .folder(SidebarFolder(id: u, name: f["title"]?.value.string ?? "Folder", expanded: expanded[u] ?? true,
                                                     items: children(of: u), icon: icon))
                    }
                    return link(nodeID(u), f).map { .link($0) }
                }
        }
        return children(of: nil)
    }
}

extension SidebarProfile {
    /// Every folder at any depth.
    static func allFolders(in items: [SidebarItem]) -> [SidebarFolder] {
        items.flatMap { item -> [SidebarFolder] in
            if case .folder(let f) = item { return [f] + allFolders(in: f.items) }
            return []
        }
    }
}
