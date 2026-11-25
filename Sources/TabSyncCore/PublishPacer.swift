import Foundation

/// When to hand a new tab list on. A change to which tabs there are, or which
/// is in front, goes at once. A tab's contents (its title, its icon) go at once
/// too when things are quiet, and at most once per `interval` while they churn:
/// a page that changes its title all day must not redraw the sidebar all day.
public struct PublishPacer: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        case now
        /// Later, this many seconds from now: the caller schedules it.
        case after(Double)
        /// One is scheduled already and will carry this change too.
        case waiting
    }

    private var last = -Double.infinity
    private var due: Double?

    public init() {}

    /// A change arrived at `now` (seconds on any steady clock).
    public mutating func changed(urgent: Bool, now: Double, interval: Double) -> Decision {
        if urgent || now - last >= interval { return .now }
        let at = last + interval
        // Scheduled at least as soon as this one would be: nothing to add.
        if let due, due <= at { return .waiting }
        due = at
        return .after(at - now)
    }

    /// The list was handed on.
    public mutating func published(now: Double) {
        last = now
        due = nil
    }

    /// Events that change only what a tab shows.
    public static func isContent(_ m: Inbound) -> Bool {
        m.type == "event" && (m.kind == "tabUpdated" || m.kind == "tabFavicon")
    }
}

/// Drains what Foundation autoreleases in a loop that never returns to a run loop.
@inline(__always)
public func pooled<T>(_ body: () throws -> T) rethrows -> T {
    #if canImport(Darwin)
    return try autoreleasepool(invoking: body)
    #else
    return try body()
    #endif
}
