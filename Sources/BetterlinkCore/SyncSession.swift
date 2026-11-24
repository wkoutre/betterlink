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

    public init(device: String, name: String, written: Date, state: SyncState) {
        self.format = Self.format; self.device = device; self.name = name; self.written = written; self.state = state
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
    }

    /// Every Mac's file that can be read now. A half-downloaded or broken file
    /// is skipped until it changes; a file from a newer betterlink is skipped
    /// and named in `newer`.
    public func readAll() -> (files: [SyncDeviceFile], skipped: [String], newer: [String]) {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        var files: [SyncDeviceFile] = [], skipped: [String] = [], newer: [String] = []
        let names = (try? FileManager.default.contentsOfDirectory(atPath: devices.path)) ?? []
        for n in names.sorted() where n.hasSuffix(".json") {
            guard let data = FileManager.default.contents(atPath: devices.appendingPathComponent(n).path) else { skipped.append(n); continue }
            if let head = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let format = head["format"] as? Int, format > SyncDeviceFile.format {
                newer.append(n); continue
            }
            guard let f = try? d.decode(SyncDeviceFile.self, from: data) else { skipped.append(n); continue }
            files.append(f)
        }
        return (files, skipped, newer)
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

    /// What the last pull changed that wasn't this Mac's own choice, for the Log.
    public struct Report: Equatable, Sendable {
        public var changedSettings = false
        public var configReplaced: URL?
        public var notes = SyncModel.Notes()
        public var skipped: [String] = []
        public var newer: [String] = []
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
            if let m = state.maxStamp { clock.observe(m) }
        }
    }

    private var rules: RuleStore { RuleStore(folder: settings) }
    private var sidebar: SidebarStore { SidebarStore(folder: settings) }
    private var configText: String? { try? String(contentsOf: settings.configFile, encoding: .utf8) }

    private func local() throws -> [String: [String: SyncValue]] {
        var out = SyncModel.project(rules: try rules.load(), library: (try? sidebar.load()) ?? .starter, selection: selection,
                                    identity: identity, state: state)
        if selection.global { out[SyncModel.globalID, default: [:]]["config"] = .of(configText) }
        return out
    }

    /// Records local changes and writes this Mac's file whenever its state
    /// differs from what the file holds: this Mac's own edits, and what it
    /// merged from other Macs, so its file always carries everything it has
    /// seen. Returns whether it wrote.
    @discardableResult
    public func push(now: Date = Date()) throws -> Bool {
        // Stamp an edit with when its file was saved, not when it was noticed,
        // so of two saves moments apart on two Macs the later one wins.
        let saved = [settings.rulesFile, settings.configFile, settings.directory.appendingPathComponent("sidebar.json")]
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .filter { $0 <= now }.max()
        state.record(try local(), scope: SyncModel.scope(selection, state: state), clock: &clock, now: Self.ms(saved ?? now))
        guard state != written || !FileManager.default.fileExists(atPath: folder.file(for: device).path) else { return false }
        try folder.write(SyncDeviceFile(device: device, name: name, written: now, state: state))
        written = state
        return true
    }

    /// Reads every Mac's file, merges, and brings this Mac's settings in line:
    /// rules.json, sidebar.json and config.ts. A config.ts replaced by a newer
    /// one from another Mac is kept beside it as a .bak. Then pushes.
    @discardableResult
    public func pull(now: Date = Date()) throws -> Report {
        var report = Report()
        // Local edits first, so they are stamped before anything newer lands.
        try push(now: now)
        let read = folder.readAll()
        report.skipped = read.skipped; report.newer = read.newer
        for f in read.files where f.device != device { state = state.merged(with: f.state) }
        otherDevices = read.files.filter { $0.device != device }.map(\.name)
        if let m = state.maxStamp { clock.observe(m) }

        let before = (try rules.load(), (try? sidebar.load()) ?? .starter)
        let r = SyncModel.materialize(state, rules: before.0, library: before.1, selection: selection, resolve: resolve)
        report.notes = r.notes
        if r.rules != before.0 { _ = try rules.update { $0 = r.rules }; report.changedSettings = true }
        if r.library != before.1 { _ = try sidebar.update { $0 = r.library }; report.changedSettings = true }
        if selection.global, let synced = state.value(SyncModel.globalID, "config") {
            let mine = configText
            if synced.string != mine {
                if let mine, !mine.isEmpty {
                    let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
                    let bak = settings.directory.appendingPathComponent("config.ts.\(Self.safe(name)).\(stamp).bak")
                    try mine.write(to: bak, atomically: true, encoding: .utf8)
                    report.configReplaced = bak
                }
                if let text = synced.string { try text.write(to: settings.configFile, atomically: true, encoding: .utf8) }
                else { try? FileManager.default.removeItem(at: settings.configFile) }
                report.changedSettings = true
            }
        }
        try push(now: now)
        return report
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
