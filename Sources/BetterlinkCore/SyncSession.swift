import Foundation

// The file side of sync (docs/sync.md, Files): one file per Mac in the sync
// folder, written only by that Mac, read by all. A SyncSession does one round
// of push or pull against plain folders, so tests can run two Macs over
// temporary folders. The app adds the folder watch and the timing.

/// One Mac's file: its whole merged state, plus who wrote it.
public struct SyncDeviceFile: Codable, Equatable, Sendable {
    public static let format = 1
    public var format: Int
    public var device: String
    public var name: String
    public var written: Date
    public var state: SyncState
    /// The browser profile this Mac put in place for each synced target
    /// (SyncModel.project). This Mac's own; other Macs ignore it.
    public var applied: [String: ProfileRef]?

    public init(device: String, name: String, written: Date, state: SyncState, applied: [String: ProfileRef]? = nil) {
        self.format = Self.format; self.device = device; self.name = name; self.written = written; self.state = state
        self.applied = applied
    }
}

/// `<sync folder>/betterlink-sync/v1/devices/<device>.json`.
public struct SyncFolder: Sendable {
    public let root: URL
    public init(_ root: URL) { self.root = root }

    public var devices: URL { root.appendingPathComponent("betterlink-sync/v1/devices", isDirectory: true) }
    public func file(for device: String) -> URL { devices.appendingPathComponent("\(device).json") }

    /// Writes this Mac's file whole: a temporary file, then a rename, so a
    /// reader never sees half of it.
    public func write(_ f: SyncDeviceFile) throws {
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        try e.encode(f).write(to: file(for: f.device), options: .atomic)
        // The rename keeps the old file's mode; a file others can change is
        // refused by every Mac (readAll), so this Mac's own file is reset.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file(for: f.device).path)
    }

    /// Every Mac's file that can be read now. A half-downloaded or broken file
    /// is skipped until it changes; a file from a newer betterlink is skipped
    /// and named in `newer`. A file that another user owns or can change, or
    /// that sits in such a folder, is refused and named in `unsafe`: device
    /// files carry Link Rules and config.ts, which is code (FileSafety, the
    /// check config.ts itself gets).
    public func readAll(except device: String? = nil, uid: uid_t = getuid()) -> (files: [SyncDeviceFile], skipped: [String], newer: [String], unsafe: [String]) {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var files: [SyncDeviceFile] = [], skipped: [String] = [], newer: [String] = [], unsafe: [String] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? []
        let own = device.map { file(for: $0).lastPathComponent }
        for n in names.sorted() where n.hasSuffix(".json") {
            // This Mac's own file is checked (other Macs refuse it the same way) but not read.
            if let problem = FileSafety.problem(with: devices.appendingPathComponent(n), uid: uid) { unsafe.append("\(n): \(problem)"); continue }
            if n == own { continue }
            guard let data = FileManager.default.contents(atPath: devices.appendingPathComponent(n).path) else { skipped.append(n); continue }
            if let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let format = head["format"] as? Int, format > SyncDeviceFile.format {
                newer.append(n); continue
            }
            guard let f = try? d.decode(SyncDeviceFile.self, from: data) else { skipped.append(n); continue }
            files.append(f)
        }
        return (files, skipped, newer, unsafe)
    }
}

/// One Mac's side of sync, against its settings folder and the sync folder.
public final class SyncSession {
    public let settings: SettingsFolder
    public let folder: SyncFolder
    public let device: String
    public let name: String
    public var selection: SyncSelection
    public var identity: (ProfileRef) -> ProfileIdentity
    public var resolve: (String, String, ProfileIdentity) -> String?
    public private(set) var state = SyncState()
    /// The other Macs whose files the last pull read, by name.
    public private(set) var otherDevices: [String] = []
    /// The other Macs the last pull read, with when each last synced.
    public private(set) var peers: [SyncPeer] = []
    private var clock: HLCClock
    /// What this Mac's file holds now, so it is rewritten whenever the state
    /// moves on, merged changes from other Macs included.
    private var written: SyncState?
    private var writtenApplied: [String: ProfileRef]?
    /// When this Mac's file was last written. It is rewritten at least
    /// daily even when nothing changed, so other Macs can tell this one is
    /// still syncing (SyncPeer's warning).
    private var writtenAt: Date?
    /// How often an unchanged file is rewritten anyway.
    public static let heartbeat: TimeInterval = 86_400
    /// What materialize last put in place for each synced target.
    private var applied: [String: ProfileRef] = [:]
    /// A push held back instead of deleting synced items (SyncGuard); nil
    /// while syncing. It is also in sync-local.json, for the CLI.
    public private(set) var held: SyncHold?
    /// The last push stamped this Mac's settings older than everything shared
    /// (joining, or a settings folder new here): what the merge then replaces
    /// is expected, not news for the history.
    private var joinedLastPush = false
    /// This Mac's own notes: the hold, the answer to it, and what sync changed here.
    public var localNotes: SyncLocalStore { SyncLocalStore(folder: settings) }

    /// Thrown by a push or pull that is held.
    public struct Held: LocalizedError {
        public let hold: SyncHold
        public var errorDescription: String? { hold.reason }
    }

    /// What the last pull changed that wasn't this Mac's own choice, for the Log.
    public struct Report: Equatable, Sendable {
        public var changedSettings = false
        public var configReplaced: URL?
        public var notes = SyncModel.Notes()
        public var skipped: [String] = []
        public var newer: [String] = []
        public var unsafe: [String] = []
        /// What sync deleted or replaced here, now in the history.
        public var recorded: [SyncHistoryEntry] = []
        /// History entries put back.
        public var restored: [SyncHistoryEntry] = []
        /// A "keep" answer to a hold was carried out.
        public var keepDone = false
    }

    public init(settings: SettingsFolder, folder: SyncFolder, device: String, name: String, selection: SyncSelection,
                identity: @escaping (ProfileRef) -> ProfileIdentity = { ProfileIdentity(name: $0.directory, account: nil) },
                resolve: @escaping (String, String, ProfileIdentity) -> String? = { _, d, _ in d }) {
        self.settings = settings; self.folder = folder; self.device = device; self.name = name
        self.selection = selection; self.identity = identity; self.resolve = resolve
        clock = HLCClock(device: device)
        // This Mac's own file carries its state across launches.
        if let mine = folder.readAll().files.first(where: { $0.device == device }) {
            state = mine.state
            written = mine.state
            writtenAt = mine.written
            applied = mine.applied ?? [:]
            writtenApplied = mine.applied
            if let m = state.maxStamp { clock.observe(m) }
        }
    }

    private var rules: RuleStore { RuleStore(folder: settings) }
    private var sidebar: SidebarStore { SidebarStore(folder: settings) }

    /// This Mac's settings files as one sync sees them, and when each was
    /// saved. Reading throws when one of them is there but unreadable, which
    /// stops the sync: reading it as empty would delete everything in it
    /// on every Mac.
    private struct Snapshot {
        var rules: RuleStore.Contents
        var library: SidebarLibrary
        var config: String?
        var rulesSaved: Date?, librarySaved: Date?, configSaved: Date?
    }

    /// A settings file changed while a sync ran.
    private struct ChangedMeanwhile: LocalizedError {
        var errorDescription: String? { "Settings kept changing during the sync. It runs again after the next change." }
    }

    private func snapshot() throws -> Snapshot {
        func saved(_ url: URL) -> Date? {
            // From the path, not the URL, which caches what it read before.
            (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
        }
        func dates() -> [Date?] { [saved(settings.rulesFile), saved(sidebar.file), saved(settings.configFile)] }
        // The dates must belong to the contents: read again when a file was
        // saved in between.
        var before = dates()
        for _ in 0..<5 {
            let snap = Snapshot(rules: try rules.load(), library: try sidebar.load(), config: try ConfigSwap.read(settings.configFile),
                                rulesSaved: before[0], librarySaved: before[1], configSaved: before[2])
            let after = dates()
            if after == before { return snap }
            before = after
        }
        throw ChangedMeanwhile()
    }

    private static func isRules(_ id: String) -> Bool { id == SyncModel.globalID || id.hasPrefix("rule:") || id.hasPrefix("mod:") }
    private static func isLibrary(_ id: String) -> Bool { id.hasPrefix("sp:") || id.hasPrefix("node:") }
    private static func isConfig(_ id: String) -> Bool { id == SyncModel.configID }

    /// Records local changes and writes this Mac's file whenever its state
    /// differs from what the file holds: this Mac's own edits, and what it
    /// merged from other Macs, so its file always carries everything it has
    /// seen. Returns whether it wrote.
    @discardableResult
    public func push(now: Date = Date()) throws -> Bool {
        try push(try snapshot(), now: now)
    }

    private func push(_ snap: Snapshot, now: Date) throws -> Bool {
        var local = SyncModel.project(rules: snap.rules, library: snap.library, selection: selection,
                                      identity: identity, state: state, applied: applied)
        if selection.global { local[SyncModel.configID] = ["text": .of(snap.config)] }
        let scope = SyncModel.scope(selection, state: state)
        let notes = localNotes.load()
        // Kept after a hold: not deleted, and the pull that follows brings them back.
        let keep = Set(notes.decision?.keep ?? [])
        let approved = Set(notes.decision?.delete ?? [])
        // Joining means this Mac has never written a file here. One that is
        // there but couldn't be read (half-downloaded, refused) doesn't count:
        // treating that Mac as new would undo its edits since its last sync.
        let joining = written == nil && !FileManager.default.fileExists(atPath: folder.file(for: device).path)
            && folder.readAll().files.contains(where: { $0.device != device })
        // A settings folder is new to sync here when its notes name another
        // device, or when it has no notes and no settings either (an empty
        // folder, as on 2026-11-25). One with settings but no notes yet is a
        // Mac that synced before the notes existed: it just gets its marker.
        let fm = FileManager.default
        let fresh = notes.device != device && (notes.device != nil
            || !(fm.fileExists(atPath: settings.rulesFile.path) || fm.fileExists(atPath: sidebar.file.path)))

        // What this Mac's settings say, stamped as edits: what the guard judges.
        var next = state, nextClock = clock
        if !joining {
            // Stamp an edit with when its file was saved, not when it was
            // noticed, so of two saves moments apart on two Macs the later
            // one wins. Each file stamps only its own settings.
            let groups: [(Date?, (String) -> Bool)] = [
                (snap.rulesSaved, Self.isRules), (snap.configSaved, Self.isConfig), (snap.librarySaved, Self.isLibrary),
            ]
            for (saved, mine) in groups {
                next.record(local.filter { mine($0.key) }, scope: { mine($0) && scope($0) && !keep.contains($0) }, clock: &nextClock,
                            now: Self.ms(saved.map { min($0, now) } ?? now))
            }
        }
        // The guard (SyncGuard): deleting many synced items at once, or any
        // from a settings folder new to sync here, waits for a person to
        // choose. Nothing is written meanwhile, and the pull doesn't run.
        let deleting = next.entities.keys.filter { state.isLive($0) && !next.isLive($0) }.sorted()
        let live = state.entities.keys.filter { scope($0) && state.isLive($0) && $0 != SyncModel.globalID && $0 != SyncModel.configID }.count
        if !Set(deleting).isSubset(of: approved),
           SyncGuard.trips(deleting: SyncSafety.roots(deleting, in: state).count, live: live, fresh: fresh)
            || SyncSafety.wipesAKind(before: state, after: next, scope: scope) {
            var hold = SyncHold(ids: deleting, names: deleting.map { SyncSafety.describe($0, in: state) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, fresh: fresh, since: now)
            if let was = notes.held, was.ids == hold.ids, was.fresh == hold.fresh { hold = was }
            else { let h = hold; try localNotes.update { $0.held = h } }
            held = hold
            // Held, it still tells the other Macs it is there: the file it
            // last wrote, unchanged but for when, once a day. Never new state.
            if let w = written, state == w, applied == (writtenApplied ?? [:]),
               let at = writtenAt, now.timeIntervalSince(at) >= Self.heartbeat {
                try folder.write(SyncDeviceFile(device: device, name: name, written: now, state: w, applied: writtenApplied))
                writtenAt = now
            }
            throw Held(hold: hold)
        }
        if joining || fresh {
            // This Mac joins Macs already syncing, or its settings folder is
            // new here: what it has is stamped older than anything shared, so
            // shared settings win every field (config.ts, the fallback, Show
            // log included) and only what is this Mac's alone is added. (The
            // first Mac in a folder stamps normally, so the next one to join
            // can't win.) Deletes it was told to make are the one exception.
            var zero = HLCClock(device: device), mine = SyncState()
            mine.record(local, scope: { _ in false }, clock: &zero, now: 0)
            next = state.merged(with: mine)
            nextClock = clock
            for id in deleting where next.isLive(id) {
                next.entities[id, default: [:]]["deleted"] = Stamped(.bool(true), nextClock.tick(now: Self.ms(now)))
            }
        }
        joinedLastPush = joining || fresh
        state = next; clock = nextClock; held = nil
        // This folder has synced as this Mac now; a hold is over, and a
        // "delete" answer is used up.
        if notes.device != device || notes.held != nil || !(notes.decision?.delete.isEmpty ?? true) {
            try localNotes.update {
                $0.device = device; $0.held = nil
                $0.decision?.delete = []
                if $0.decision?.isEmpty == true { $0.decision = nil }
            }
        }
        guard state != written || applied != (writtenApplied ?? [:])
                || writtenAt.map({ now.timeIntervalSince($0) >= Self.heartbeat }) ?? false
                || !FileManager.default.fileExists(atPath: folder.file(for: device).path) else { return false }
        try folder.write(SyncDeviceFile(device: device, name: name, written: now, state: state, applied: applied))
        written = state
        writtenAt = now
        writtenApplied = applied
        return true
    }

    /// Reads every Mac's file, merges, and brings this Mac's settings in line:
    /// rules.json, sidebar.json and config.ts. A config.ts replaced by a newer
    /// one from another Mac is kept beside it as a .bak. Then pushes.
    ///
    /// The CLI, an editor and the app can write those files at any moment. A
    /// file is written only if it is still what this sync read (checked under
    /// its store's lock); if not, the sync starts over with the new contents.
    @discardableResult
    public func pull(now: Date = Date()) throws -> Report {
        var report = Report()
        // What this pull takes away here, by entity: a sync that starts over
        // may already have applied some of it, so the first finding counts.
        var found: [String: SyncHistoryEntry] = [:]
        let batch = UUID()
        do {
            for attempt in 1... {
                do { try pullOnce(now: now, batch: batch, &found, &report); break }
                catch is ConfigSwap.Changed { if attempt == 10 { throw ChangedMeanwhile() } }
                catch let e as ChangedMeanwhile { if attempt == 10 { throw e } }
            }
        } catch {
            // What an attempt already applied here stays in the history.
            try? saveNotes(found, report, now: now, done: false)
            throw error
        }
        // Before the last push, which can still be held: what this pull did is noted.
        try saveNotes(found, report, now: now, done: true)
        report.recorded = found.values.sorted { $0.entity < $1.entity }
        try push(now: now)
        return report
    }

    /// Saves what a pull applied in this Mac's notes: the history entries,
    /// and, when it finished (`done`), the restores, the Keep it carried out
    /// and the rules whose profile this Mac lacks (for the Link Rules page
    /// and `rules list`).
    private func saveNotes(_ found: [String: SyncHistoryEntry], _ report: Report, now: Date, done: Bool) throws {
        let recorded = found.values.sorted { $0.entity < $1.entity }
        let restored = done ? Set(report.restored.map(\.id)) : []
        let keepDone = done && report.keepDone
        let unresolved = report.notes.unresolvedRules.sorted { $0.uuidString < $1.uuidString }
        let before = localNotes.load()
        guard !recorded.isEmpty || !restored.isEmpty || keepDone
                || (done && (!before.restore.isEmpty || (before.unresolvedRules ?? []) != unresolved)) else { return }
        try localNotes.update { notes in
            if done {
                notes.unresolvedRules = unresolved.isEmpty ? nil : unresolved
                // Asked for and done, or no longer in the history: either way, settled.
                let known = Set(notes.history.map(\.id))
                notes.restore.removeAll { restored.contains($0) || !known.contains($0) }
            }
            notes.history.removeAll { restored.contains($0.id) }
            notes.record(recorded, now: now)
            if keepDone {
                notes.decision?.keep = []
                if notes.decision?.isEmpty == true { notes.decision = nil }
            }
        }
    }

    private func pullOnce(now: Date, batch: UUID, _ found: inout [String: SyncHistoryEntry], _ report: inout Report) throws {
        // Local edits first, so they are stamped before anything newer lands.
        let snap = try snapshot()
        _ = try push(snap, now: now)
        let notes = localNotes.load()
        // This Mac's own file says nothing it doesn't know, and can be megabytes.
        let read = folder.readAll(except: device)
        report.skipped = read.skipped; report.newer = read.newer; report.unsafe = read.unsafe
        var merged = state
        for f in read.files where f.device != device { merged = merged.merged(with: f.state) }
        otherDevices = read.files.filter { $0.device != device }.map(\.name)
        peers = folder.peers(read.files.filter { $0.device != device })
        if let m = merged.maxStamp { clock.observe(m) }

        // What the merge deletes or replaces here goes in the history, with
        // the value it had, so Sync settings can put it back.
        // Not on a Mac's first sync: its own values losing then is expected.
        // An entry counts once its group of settings is written (adopt below).
        let names = Dictionary(read.files.map { ($0.device, $0.name) }, uniquingKeysWith: { a, _ in a })
        var pending: [String: SyncHistoryEntry] = [:]
        if !joinedLastPush {
            for e in SyncSafety.changes(from: state, to: merged, scope: SyncModel.scope(selection, state: state), names: names,
                                        now: now, batch: batch) where found[e.entity] == nil {
                pending[e.entity] = e
            }
        }
        // A Restore is a new edit on this Mac: the old values, stamped now,
        // so they win on every Mac.
        report.restored = SyncSafety.restoring(notes.restore, from: notes.history)
        for e in report.restored {
            for (k, v) in e.previous.sorted(by: { $0.key < $1.key }) {
                merged.entities[e.entity, default: [:]][k] = Stamped(v, clock.tick(now: Self.ms(now)))
            }
            if e.kind == .deleted { merged.entities[e.entity, default: [:]]["deleted"] = Stamped(.bool(false), clock.tick(now: Self.ms(now))) }
            pending[e.entity] = nil; found[e.entity] = nil
        }
        report.keepDone = !(notes.decision?.keep.isEmpty ?? true)

        // `state` takes the merge one file at a time, once that file holds it:
        // the next push records whatever the files say that `state` doesn't,
        // so merging ahead of a file that isn't written would stamp this Mac's
        // old values as new edits and revert the other Mac's.
        func adopt(_ mine: (String) -> Bool) {
            for (id, fields) in merged.entities where mine(id) { state.entities[id] = fields }
            for (id, e) in pending where mine(id) { found[id] = e }
        }
        let r = SyncModel.materialize(merged, rules: snap.rules, library: snap.library, selection: selection, resolve: resolve)
        // A sync that starts over may have moved things already: keep its notes.
        report.notes.unresolvedRules = r.notes.unresolvedRules
        report.notes.orphansMovedToTop += r.notes.orphansMovedToTop.filter { !report.notes.orphansMovedToTop.contains($0) }
        report.notes.cyclesBroken += r.notes.cyclesBroken.filter { !report.notes.cyclesBroken.contains($0) }

        try replace(snap.rules, with: r.rules, in: rules.update, &report)
        applied = r.applied
        adopt(Self.isRules)

        try replace(snap.library, with: r.library, in: sidebar.update, &report)
        adopt(Self.isLibrary)

        if selection.global, let synced = merged.value(SyncModel.configID, "text"), synced.string != snap.config {
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            report.configReplaced = try ConfigSwap.replace(settings.configFile, expected: snap.config, with: synced.string,
                                                           backup: "config.ts.\(Self.safe(name)).\(stamp)")
            report.changedSettings = true
        }
        state = merged
    }

    /// Writes `new` over `old` under the store's lock, unless the file is no
    /// longer `old`.
    private func replace<T: Equatable>(_ old: T, with new: T, in update: ((inout T) throws -> Void) throws -> T,
                                       _ report: inout Report) throws {
        guard new != old else { return }
        _ = try update { now in
            guard now == old else { throw ChangedMeanwhile() }
            now = new
        }
        report.changedSettings = true
    }

    /// Sidebar Profiles other Macs share that aren't in this Mac's selection,
    /// to offer with an Add button.
    public func offeredProfiles(localIDs: Set<UUID>) -> [(id: UUID, name: String)] {
        state.entities.keys.filter { $0.hasPrefix("sp:") && state.isLive($0) }
            .compactMap { k -> (id: UUID, name: String)? in
                guard let u = SyncModel.uuid(k), !localIDs.contains(u) else { return nil }
                return (u, state.value(k, "name")?.string ?? "Sidebar Profile")
            }
            .sorted { $0.name < $1.name }
    }

    static func ms(_ d: Date) -> Int64 { Int64(d.timeIntervalSince1970 * 1000) }
    static func safe(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber ? $0 : "-" }) }
}
