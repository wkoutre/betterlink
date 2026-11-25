import Foundation

// Sync between Macs (docs/sync.md). This file is the part every Mac must agree
// on: stamps, the merge, and turning betterlink's settings into stamped fields
// and back. Files, folders and the UI live elsewhere.

// MARK: - Hybrid logical clock

/// A stamp: wall-clock milliseconds, a counter for edits within the same
/// millisecond, and the device that made it. Stamps compare in that order, so
/// two are never equal, and every Mac orders them the same way.
public struct HLC: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public var wall: Int64
    public var counter: Int
    public var device: String

    public init(wall: Int64, counter: Int, device: String) {
        self.wall = wall; self.counter = counter; self.device = device
    }

    public static func < (a: HLC, b: HLC) -> Bool {
        (a.wall, a.counter, a.device) < (b.wall, b.counter, b.device)
    }

    public var description: String { "\(wall).\(counter)@\(device)" }
}

/// Hands out stamps that never go back: never below the clock, never below
/// any stamp this Mac has seen. A Mac whose clock is behind still stamps its
/// edits after everything it has merged.
public struct HLCClock: Sendable {
    public let device: String
    public private(set) var last: HLC

    public init(device: String, last: HLC? = nil) {
        self.device = device
        self.last = last ?? HLC(wall: 0, counter: 0, device: device)
    }

    public mutating func tick(now: Int64) -> HLC {
        if now > last.wall { last = HLC(wall: now, counter: 0, device: device) }
        else { last = HLC(wall: last.wall, counter: last.counter + 1, device: device) }
        return last
    }

    public mutating func observe(_ other: HLC) {
        if other.wall > last.wall || (other.wall == last.wall && other.counter > last.counter) {
            last = HLC(wall: other.wall, counter: other.counter, device: device)
        }
    }
}

// MARK: - Values and state

/// A field's value: what JSON can hold.
public enum SyncValue: Codable, Equatable, Hashable, Sendable {
    case null
    case bool(Bool)
    case string(String)
    case number(Double)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }

    public static func of(_ s: String?) -> SyncValue { s.map { .string($0) } ?? .null }
}

public struct Stamped: Codable, Equatable, Sendable {
    public var value: SyncValue
    public var stamp: HLC
    public init(_ value: SyncValue, _ stamp: HLC) { self.value = value; self.stamp = stamp }
}

/// Every synced entity's fields, each with its stamp. Entity ids carry their
/// kind: "rule:…", "mod:…", "sp:…" (a Sidebar Profile), "node:…" (a favorite,
/// folder or saved link), "global".
public struct SyncState: Codable, Equatable, Sendable {
    public var entities: [String: [String: Stamped]]

    public init(entities: [String: [String: Stamped]] = [:]) { self.entities = entities }

    /// The merge every Mac runs: per entity and field, the higher stamp wins.
    /// Commutative, associative and idempotent, so any files in any order, any
    /// number of times, give the same state.
    public func merged(with other: SyncState) -> SyncState {
        var out = entities
        for (id, fields) in other.entities {
            var mine = out[id] ?? [:]
            for (k, v) in fields where mine[k].map({ v.stamp > $0.stamp }) ?? true { mine[k] = v }
            out[id] = mine
        }
        return SyncState(entities: out)
    }

    /// The highest stamp anywhere, for the clock to start after.
    public var maxStamp: HLC? { entities.values.flatMap(\.values).map(\.stamp).max() }

    public func value(_ id: String, _ field: String) -> SyncValue? { entities[id]?[field]?.value }
    public func isLive(_ id: String) -> Bool { entities[id] != nil && value(id, "deleted")?.bool != true }

    /// Writes this Mac's view of the entities in `scope`: any field whose value
    /// differs from the state gets a new stamp; an entity in scope that the
    /// local settings no longer have is marked deleted; one that came back is
    /// marked live. Returns whether anything changed.
    @discardableResult
    public mutating func record(_ local: [String: [String: SyncValue]], scope: (String) -> Bool,
                                clock: inout HLCClock, now: Int64) -> Bool {
        var changed = false
        func set(_ id: String, _ k: String, _ v: SyncValue) {
            if entities[id]?[k]?.value == v { return }
            entities[id, default: [:]][k] = Stamped(v, clock.tick(now: now))
            changed = true
        }
        for (id, fields) in local.sorted(by: { $0.key < $1.key }) {
            for (k, v) in fields.sorted(by: { $0.key < $1.key }) { set(id, k, v) }
            if entities[id]?["deleted"]?.value != .bool(false) { set(id, "deleted", .bool(false)) }
        }
        for id in entities.keys.sorted() where scope(id) && local[id] == nil && isLive(id) {
            set(id, "deleted", .bool(true))
        }
        return changed
    }
}

// MARK: - Order

/// Fractional indexes: strings that sort between their neighbours, so an
/// insert or a move never renumbers the rest of a list.
public enum FractionalIndex {
    static let digits = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    /// A key after `a` (nil: the start) and before `b` (nil: the end), for
    /// a < b. Keys never end in "0", so there is always room between two.
    public static func between(_ a: String?, _ b: String?) -> String {
        func idx(_ s: String) -> [Int] { s.map { digits.firstIndex(of: $0) ?? 0 } }
        let out = midpoint(idx(a ?? ""), b.map(idx))
        return String(out.map { digits[$0] })
    }

    private static func midpoint(_ a: [Int], _ b: [Int]?) -> [Int] {
        if let b {
            var n = 0
            while n < b.count, (n < a.count ? a[n] : 0) == b[n] { n += 1 }
            if n > 0 { return Array(b.prefix(n)) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n))) }
        }
        let da = a.first ?? 0
        let db = b.flatMap(\.first) ?? digits.count
        if db - da > 1 { return [(da + db + 1) / 2] }
        // Adjacent first digits: b's first digit alone fits when b goes on,
        // else keep a's first digit and go above the rest of a.
        if let b, b.count > 1 { return [b[0]] }
        return [da] + midpoint(Array(a.dropFirst()), nil)
    }

    /// Positions for `ids` in this order, keeping each existing position
    /// that still sorts after the one before it and making new ones only
    /// where needed, between the neighbours.
    public static func positions(for ids: [String], existing: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        var prev: String?
        for (n, id) in ids.enumerated() {
            if let p = existing[id], prev.map({ p > $0 }) ?? true {
                out[id] = p; prev = p; continue
            }
            let next = ids[(n + 1)...].lazy.compactMap { existing[$0] }.first { q in prev.map { q > $0 } ?? true }
            let p = between(prev, next)
            out[id] = p; prev = p
        }
        return out
    }
}
