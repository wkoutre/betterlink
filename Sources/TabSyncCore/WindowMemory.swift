import Foundation

/// What was chosen for one browser window's sidebar, kept across launches:
/// hidden or shown, and how wide. A window with nothing chosen follows the
/// settings. Known by its window-server number like FitMemory's, and by its
/// process, since the numbers start over when the Mac restarts.
public struct WindowMemory: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var window: UInt32
        public var pid: Int32
        public var hidden: Bool?
        public var width: Double?
    }

    public private(set) var entries: [Entry] = []
    public init() {}

    public func hidden(window: UInt32, pid: Int32) -> Bool? { entry(window, pid)?.hidden }
    public func width(window: UInt32, pid: Int32) -> Double? { entry(window, pid)?.width }

    public mutating func set(hidden: Bool, window: UInt32, pid: Int32) { change(window, pid) { $0.hidden = hidden } }
    public mutating func set(width: Double, window: UInt32, pid: Int32) { change(window, pid) { $0.width = width } }

    /// Set for every window at once: each follows the setting again.
    public mutating func forgetHidden() { forget { $0.hidden = nil } }
    public mutating func forgetWidths() { forget { $0.width = nil } }

    public mutating func forget(window: UInt32) { entries.removeAll { $0.window == window } }

    /// Drops the records of windows that no longer exist.
    public mutating func prune(alive: Set<UInt32>) { entries.removeAll { !alive.contains($0.window) } }

    private func entry(_ window: UInt32, _ pid: Int32) -> Entry? { entries.last { $0.window == window && $0.pid == pid } }

    private mutating func change(_ window: UInt32, _ pid: Int32, _ body: (inout Entry) -> Void) {
        var e = entry(window, pid) ?? Entry(window: window, pid: pid)
        body(&e)
        entries.removeAll { $0.window == window }
        entries.append(e)
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
    }

    private mutating func forget(_ body: (inout Entry) -> Void) {
        for i in entries.indices { body(&entries[i]) }
        entries.removeAll { $0.hidden == nil && $0.width == nil }
    }
}
