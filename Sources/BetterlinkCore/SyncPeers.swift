import Foundation

// The other Macs in a sync folder, for Sync settings and `betterlink sync
// get`: each one's name and when its file was last written, and a warning
// for one that has gone quiet (docs/sync.md, Other Macs).

/// Another Mac that writes into the sync folder.
public struct SyncPeer: Equatable, Sendable, Identifiable {
    public var device: String
    public var name: String
    /// When it last wrote its file, from the file itself (`written`, in
    /// every device file since format 1), not the file's date, which a
    /// cloud app sets when it downloads the file.
    public var synced: Date
    public var id: String { device }

    public init(device: String, name: String, synced: Date) {
        self.device = device; self.name = name; self.synced = synced
    }

    /// A Mac quiet this long is flagged.
    public static let staleDays = 7

    /// Whole days since it last synced.
    public func days(now: Date) -> Int { max(0, Int(now.timeIntervalSince(synced) / 86_400)) }

    public func isStale(now: Date) -> Bool { days(now: now) >= Self.staleDays }

    /// "Nick's Mac mini, synced 3:12 PM", "…, synced yesterday at 3:12 PM", "…, synced Nov 20".
    public func summary(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.locale = locale
        let when: String
        if calendar.isDate(synced, inSameDayAs: now) {
            f.dateStyle = .none; f.timeStyle = .short
            when = f.string(from: synced)
        } else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(synced, inSameDayAs: y) {
            f.dateStyle = .none; f.timeStyle = .short
            when = "yesterday at \(f.string(from: synced))"
        } else {
            let sameYear = calendar.component(.year, from: synced) == calendar.component(.year, from: now)
            f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
            when = f.string(from: synced)
        }
        return "\(name), synced \(when)"
    }

    /// For a Mac quiet a week or more: "hasn't synced in 9 days; it may be off or signed out of the sync folder".
    public func warning(now: Date) -> String? {
        guard isStale(now: now) else { return nil }
        return "hasn't synced in \(days(now: now)) days; it may be off or signed out of the sync folder"
    }

    /// The CLI's entry for it.
    public func describe(now: Date) -> [String: Any] {
        ["device": device, "name": name, "synced": ISO8601DateFormatter().string(from: synced),
         "summary": summary(now: now), "stale": isStale(now: now), "warning": warning(now: now) ?? NSNull()]
    }
}

extension SyncFolder {
    /// The Macs whose files can be read now, other than `device`, by name.
    public func peers(except device: String?) -> [SyncPeer] {
        peers(readAll(except: device).files.filter { $0.device != device })
    }

    func peers(_ files: [SyncDeviceFile]) -> [SyncPeer] {
        files.map { SyncPeer(device: $0.device, name: $0.name, synced: $0.written) }
        .sorted { ($0.name, $0.device) < ($1.name, $1.device) }
    }
}
