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
        for n in names.sorted() where n.hasSuffix(".json") && n != own {
            if let problem = FileSafety.problem(with: devices.appendingPathComponent(n), uid: uid) { unsafe.append("\(n): \(problem)"); continue }
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
    private var clock: HLCClock
    /// What this Mac's file holds now, so it is rewritten whenever the state
    /// moves on, merged changes from other Macs included.
    private var written: SyncState?
    private var writtenApplied: [String: ProfileRef]?
    /// What materialize last put in place for each synced target.
    private var applied: [String: ProfileRef] = [:]

    /// What the last pull changed that wasn't this Mac's own choice, for the Log.
    public struct Report: Equatable, Sendable {
        public var changedSettings = false
        public var configReplaced: URL?
        public var notes = SyncModel.Notes()
        public var skipped: [String] = []
        public var newer: [String] = []
        public var unsafe: [String] = []
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
        // Joining means this Mac has never written a file here. One that is
        // there but couldn't be read (half-downloaded, refused) doesn't count:
        // treating that Mac as new would undo its edits since its last sync.
        if written == nil, !FileManager.default.fileExists(atPath: folder.file(for: device).path),
           folder.readAll().files.contains(where: { $0.device != device }) {
            // This Mac joins Macs already syncing: what it has is stamped
            // older than anything they shared, so shared settings win and
            // only what is this Mac's alone is added. (The first Mac in a
            // folder stamps normally, so the next one to join can't win.)
            var zero = HLCClock(device: device)
            state.record(local, scope: { _ in false }, clock: &zero, now: 0)
        } else {
            // Stamp an edit with when its file was saved, not when it was
            // noticed, so of two saves moments apart on two Macs the later
            // one wins. Each file stamps only its own settings.
            let groups: [(Date?, (String) -> Bool)] = [
                (snap.rulesSaved, Self.isRules), (snap.configSaved, Self.isConfig), (snap.librarySaved, Self.isLibrary),
            ]
            for (saved, mine) in groups {
                state.record(local.filter { mine($0.key) }, scope: { mine($0) && scope($0) }, clock: &clock,
                             now: Self.ms(saved.map { min($0, now) } ?? now))
            }
        }
        guard state != written || applied != (writtenApplied ?? [:])
                || !FileManager.default.fileExists(atPath: folder.file(for: device).path) else { return false }
        try folder.write(SyncDeviceFile(device: device, name: name, written: now, state: state, applied: applied))
        written = state
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
        for attempt in 1... {
            do { try pullOnce(now: now, &report); break }
            catch is ConfigSwap.Changed { if attempt == 10 { throw ChangedMeanwhile() } }
            catch let e as ChangedMeanwhile { if attempt == 10 { throw e } }
        }
        try push(now: now)
        return report
    }

    private func pullOnce(now: Date, _ report: inout Report) throws {
        // Local edits first, so they are stamped before anything newer lands.
        let snap = try snapshot()
        _ = try push(snap, now: now)
        // This Mac's own file says nothing it doesn't know, and can be megabytes.
        let read = folder.readAll(except: device)
        report.skipped = read.skipped; report.newer = read.newer; report.unsafe = read.unsafe
        var merged = state
        for f in read.files where f.device != device { merged = merged.merged(with: f.state) }
        otherDevices = read.files.filter { $0.device != device }.map(\.name)
        if let m = merged.maxStamp { clock.observe(m) }

        // `state` takes the merge one file at a time, once that file holds it:
        // the next push records whatever the files say that `state` doesn't,
        // so merging ahead of a file that isn't written would stamp this Mac's
        // old values as new edits and revert the other Mac's.
        func adopt(_ mine: (String) -> Bool) {
            for (id, fields) in merged.entities where mine(id) { state.entities[id] = fields }
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
