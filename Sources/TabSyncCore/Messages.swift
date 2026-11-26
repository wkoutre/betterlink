import Foundation

/// One tab as the browser extension serializes it (extension/bridge.js `serializeTab`).
public struct Tab: Codable, Equatable, Identifiable, Sendable {
    public var id: Int
    public var windowId: Int
    public var index: Int
    public var title: String
    public var url: String
    public var favIconUrl: String
    public var active: Bool
    public var pinned: Bool
    public var audible: Bool
    /// Silenced by the person or the app (an extension older than 0.2 never says so).
    public var muted: Bool
    public var status: String

    public init(id: Int, windowId: Int, index: Int = 0, title: String = "", url: String = "",
                favIconUrl: String = "", active: Bool = false, pinned: Bool = false,
                audible: Bool = false, muted: Bool = false, status: String = "") {
        self.id = id; self.windowId = windowId; self.index = index; self.title = title
        self.url = url; self.favIconUrl = favIconUrl; self.active = active; self.pinned = pinned
        self.audible = audible; self.muted = muted; self.status = status
    }

    /// Only the ids are required: a field an older or newer extension leaves
    /// out takes its default instead of dropping the whole message.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        windowId = try c.decode(Int.self, forKey: .windowId)
        index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        favIconUrl = try c.decodeIfPresent(String.self, forKey: .favIconUrl) ?? ""
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        audible = try c.decodeIfPresent(Bool.self, forKey: .audible) ?? false
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? ""
    }
}

public struct SnapshotWindow: Codable, Equatable, Sendable {
    public var id: Int
    public var focused: Bool
    public var incognito: Bool?
    /// "normal", "popup" or "app" (extension 0.3.2 and later).
    public var windowType: String?
    public var tabs: [Tab]
    public var left: Double?
    public var top: Double?
    public var width: Double?
    public var height: Double?

    public init(id: Int, focused: Bool, incognito: Bool? = nil, windowType: String? = nil, tabs: [Tab],
                left: Double? = nil, top: Double? = nil, width: Double? = nil, height: Double? = nil) {
        self.id = id; self.focused = focused; self.incognito = incognito; self.windowType = windowType; self.tabs = tabs
        self.left = left; self.top = top; self.width = width; self.height = height
    }

    public var bounds: WindowBounds? { WindowBounds(left: left, top: top, width: width, height: height) }
}

/// A browser window's frame in screen points, top-left origin: the browser's
/// `chrome.windows` bounds, which use the same space as macOS Accessibility.
public struct WindowBounds: Equatable, Sendable {
    public var left, top, width, height: Double

    public init(left: Double, top: Double, width: Double, height: Double) {
        self.left = left; self.top = top; self.width = width; self.height = height
    }

    init?(left: Double?, top: Double?, width: Double?, height: Double?) {
        guard let left, let top, let width, let height else { return nil }
        self.init(left: left, top: top, width: width, height: height)
    }

    /// How far apart two frames are: the sum of their edges' distances.
    public func distance(to o: WindowBounds) -> Double {
        abs(left - o.left) + abs(top - o.top) + abs(left + width - o.left - o.width) + abs(top + height - o.top - o.height)
    }
}

/// Everything the extension (or the host) can send to the app. One flat shape
/// keyed by `type` / `kind`, so decoding never fails on a new optional field.
public struct Inbound: Codable, Sendable {
    public var type: String              // hello | snapshot | event | ack | host
    public var kind: String?             // for type == event
    public var seq: Int?
    public var t: Double?                // browser clock, ms since epoch
    public var tab: Tab?
    public var tabId: Int?
    public var removedTabId: Int?
    public var windowId: Int?
    public var fromIndex: Int?
    public var toIndex: Int?
    public var isWindowClosing: Bool?
    public var focused: Bool?
    public var incognito: Bool?
    /// windowCreated: "normal", "popup" or "app" (`type` is the message's own).
    public var windowType: String?
    public var windows: [SnapshotWindow]?
    // windowCreated / windowBounds
    public var left: Double?
    public var top: Double?
    public var width: Double?
    public var height: Double?
    /// hello: a random id the extension keeps in this browser profile's storage.
    public var instance: String?
    public var changes: [String]?
    /// tabFavicon: the icon as a data: URL.
    public var favicon: String?
    // hello
    public var protocolVersion: Int?
    public var extensionVersion: String?
    /// hello: the commands this copy of the extension runs (0.2 and later).
    public var ops: [String]?
    public var userAgent: String?
    public var brands: [String]?
    // ack (`tabId`: the tab an open or duplicate made)
    public var id: String?
    public var ok: Bool?
    public var error: String?
    // host
    public var browser: String?
    public var pid: Int?
    /// The browser process that launched the host (matches NSRunningApplication.processIdentifier).
    public var browserPid: Int?

    enum CodingKeys: String, CodingKey {
        case type, kind, seq, t, tab, tabId, removedTabId, windowId, fromIndex, toIndex,
             isWindowClosing, focused, incognito, windowType, windows, left, top, width, height, instance, changes, favicon, ops, userAgent, brands, id, ok, error, browser, pid, browserPid
        case protocolVersion = "protocol"
        case extensionVersion = "extension"
    }

    public init(type: String) { self.type = type }
}

/// A command from the app to the browser.
public struct Command: Codable, Equatable, Sendable {
    public var type = "cmd"
    public var id: String
    /// One of `Command.Op`.
    public var op: String
    public var url: String?
    public var tabId: Int?
    public var tabIds: [Int]?
    public var windowId: Int?
    /// move: where the tab goes in its window's tab order.
    public var index: Int?
    public var muted: Bool?
    public var focus: Bool?
    public var t: Double

    /// Every command. The first four are the ones every extension runs; the
    /// rest arrived with extension 0.2, which lists what it runs in its hello.
    /// `reloadSelf` arrived with 0.3.
    public enum Op: String, CaseIterable, Sendable {
        case snapshot, open, close, activate
        case move, mute, duplicate, reload, navigate, closeMany, newWindow
        case reloadSelf

        /// What an extension that sends no list (0.1) runs.
        public static let original: Set<String> = [Op.snapshot, .open, .close, .activate].reduce(into: []) { $0.insert($1.rawValue) }
    }

    init(_ op: Op, url: String? = nil, tabId: Int? = nil, tabIds: [Int]? = nil, windowId: Int? = nil,
         index: Int? = nil, muted: Bool? = nil, focus: Bool? = nil) {
        id = UUID().uuidString; self.op = op.rawValue; self.url = url; self.tabId = tabId; self.tabIds = tabIds
        self.windowId = windowId; self.index = index; self.muted = muted; self.focus = focus; t = nowMs()
    }

    public static func open(_ url: String, windowId: Int? = nil) -> Command {
        Command(.open, url: url, windowId: windowId, focus: true)
    }
    public static func close(_ tabId: Int) -> Command { Command(.close, tabId: tabId) }
    public static func activate(_ tabId: Int) -> Command { Command(.activate, tabId: tabId, focus: true) }
    public static func snapshot() -> Command { Command(.snapshot) }
    /// Moves a tab to `index` in its window, or in `windowId` when given.
    public static func move(_ tabId: Int, to index: Int, windowId: Int? = nil) -> Command {
        Command(.move, tabId: tabId, windowId: windowId, index: index)
    }
    public static func mute(_ tabId: Int, _ muted: Bool) -> Command { Command(.mute, tabId: tabId, muted: muted) }
    public static func duplicate(_ tabId: Int) -> Command { Command(.duplicate, tabId: tabId) }
    public static func reload(_ tabId: Int) -> Command { Command(.reload, tabId: tabId) }
    /// Sends a tab to `url` and shows it.
    public static func navigate(_ tabId: Int, to url: String) -> Command {
        Command(.navigate, url: url, tabId: tabId, focus: true)
    }
    public static func close(_ tabIds: [Int]) -> Command { Command(.closeMany, tabIds: tabIds) }
    /// Moves a tab out of its window into a new one of its own.
    public static func newWindow(with tabId: Int) -> Command { Command(.newWindow, tabId: tabId) }
    /// Asks the extension to restart from its files on disk. It does only when
    /// they are another version than the one running (see `ExtensionCopy`).
    public static func reloadSelf() -> Command { Command(.reloadSelf) }
}

public func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
