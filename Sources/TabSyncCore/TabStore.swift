import Foundation

public struct BrowserWindow: Equatable, Identifiable, Sendable {
    public var id: Int
    public var focused: Bool
    public var incognito: Bool
    public var tabIds: [Int]
}

/// The app's mirror of one browser's tabs. It is a pure reducer: feed it the
/// extension's messages in order and it holds exactly the browser's state.
/// Order inside a window is kept as an id list, so Chrome's index semantics
/// (insert at index, move from/to, attach at position) apply directly.
public struct TabStore: Equatable, Sendable {
    public private(set) var windows: [Int: BrowserWindow] = [:]
    public private(set) var windowOrder: [Int] = []
    public private(set) var tabs: [Int: Tab] = [:]
    public private(set) var lastSeq: Int = 0
    public private(set) var hasSnapshot = false

    public init() {}

    public enum Outcome: Equatable {
        case applied
        case ignored
        /// A sequence gap (a dropped message): the caller should ask for a snapshot.
        case needsSnapshot
    }

    @discardableResult
    public mutating func apply(_ m: Inbound) -> Outcome {
        switch m.type {
        case "snapshot":
            loadSnapshot(m.windows ?? [])
            lastSeq = m.seq ?? 0
            hasSnapshot = true
            return .applied
        case "event":
            guard hasSnapshot else { return .ignored } // the snapshot that follows covers it
            if let s = m.seq {
                if s <= lastSeq { return .ignored }       // already folded into a later snapshot
                if s != lastSeq + 1 { lastSeq = s; return .needsSnapshot }
                lastSeq = s
            }
            applyEvent(m)
            return .applied
        default:
            return .ignored
        }
    }

    public struct WindowEntry: Identifiable, Sendable {
        public var window: BrowserWindow
        public var tabs: [Tab]
        public var id: Int { window.id }
    }

    /// Windows in display order, each with its tabs in tab-strip order.
    public var orderedWindows: [WindowEntry] {
        windowOrder.compactMap { wid in
            guard let w = windows[wid] else { return nil }
            return WindowEntry(window: w, tabs: w.tabIds.enumerated().compactMap { i, id in
                guard var t = tabs[id] else { return nil }
                t.index = i
                return t
            })
        }
    }

    public var tabCount: Int { tabs.count }

    // MARK: - internals

    private mutating func loadSnapshot(_ wins: [SnapshotWindow]) {
        windows = [:]; windowOrder = []; tabs = [:]
        for w in wins {
            let sorted = w.tabs.sorted { $0.index < $1.index }
            windows[w.id] = BrowserWindow(id: w.id, focused: w.focused, incognito: w.incognito ?? false, tabIds: sorted.map(\.id))
            windowOrder.append(w.id)
            for t in sorted { tabs[t.id] = t }
        }
    }

    private mutating func ensureWindow(_ id: Int) {
        if windows[id] == nil {
            windows[id] = BrowserWindow(id: id, focused: false, incognito: false, tabIds: [])
            windowOrder.append(id)
        }
    }

    private mutating func insert(_ tabId: Int, window wid: Int, at index: Int) {
        ensureWindow(wid)
        var ids = windows[wid]!.tabIds.filter { $0 != tabId }
        ids.insert(tabId, at: max(0, min(index, ids.count)))
        windows[wid]!.tabIds = ids
        tabs[tabId]?.windowId = wid
    }

    private mutating func unlink(_ tabId: Int, window wid: Int?) {
        if let wid, windows[wid] != nil {
            windows[wid]!.tabIds.removeAll { $0 == tabId }
        } else {
            for k in windows.keys { windows[k]!.tabIds.removeAll { $0 == tabId } }
        }
    }

    private mutating func setActive(_ tabId: Int, window wid: Int) {
        for id in windows[wid]?.tabIds ?? [] { tabs[id]?.active = (id == tabId) }
    }

    private mutating func applyEvent(_ m: Inbound) {
        switch m.kind {
        case "tabCreated":
            guard let t = m.tab else { return }
            tabs[t.id] = t
            insert(t.id, window: t.windowId, at: t.index)
            if t.active { setActive(t.id, window: t.windowId) }
        case "tabUpdated":
            guard let t = m.tab else { return }
            let known = tabs[t.id] != nil
            tabs[t.id] = t
            if !known { insert(t.id, window: t.windowId, at: t.index) }
        case "tabRemoved":
            guard let id = m.tabId else { return }
            unlink(id, window: m.windowId)
            tabs[id] = nil
        case "tabMoved":
            guard let id = m.tabId, let wid = m.windowId, let to = m.toIndex else { return }
            insert(id, window: wid, at: to)
        case "tabActivated":
            guard let id = m.tabId, let wid = m.windowId else { return }
            setActive(id, window: wid)
        case "tabDetached":
            guard let id = m.tabId else { return }
            unlink(id, window: m.windowId)
        case "tabAttached":
            guard let id = m.tabId, let wid = m.windowId else { return }
            insert(id, window: wid, at: m.toIndex ?? Int.max)
        case "tabReplaced":
            guard let added = m.tabId, let removed = m.removedTabId else { return }
            for (wid, w) in windows {
                if let i = w.tabIds.firstIndex(of: removed) { windows[wid]!.tabIds[i] = added }
            }
            var t = m.tab ?? tabs[removed] ?? Tab(id: added, windowId: tabs[removed]?.windowId ?? -1)
            t.id = added
            tabs[removed] = nil
            tabs[added] = t
        case "windowCreated":
            guard let wid = m.windowId else { return }
            ensureWindow(wid)
            windows[wid]!.incognito = m.incognito ?? false
        case "windowRemoved":
            guard let wid = m.windowId else { return }
            for id in windows[wid]?.tabIds ?? [] { tabs[id] = nil }
            windows[wid] = nil
            windowOrder.removeAll { $0 == wid }
        case "windowFocused":
            guard let wid = m.windowId else { return }
            for k in windows.keys { windows[k]!.focused = (k == wid) }
        default:
            break
        }
    }
}
