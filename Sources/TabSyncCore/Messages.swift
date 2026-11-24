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
    public var status: String

    public init(id: Int, windowId: Int, index: Int = 0, title: String = "", url: String = "",
                favIconUrl: String = "", active: Bool = false, pinned: Bool = false,
                audible: Bool = false, status: String = "") {
        self.id = id; self.windowId = windowId; self.index = index; self.title = title
        self.url = url; self.favIconUrl = favIconUrl; self.active = active; self.pinned = pinned
        self.audible = audible; self.status = status
    }
}

public struct SnapshotWindow: Codable, Equatable, Sendable {
    public var id: Int
    public var focused: Bool
    public var incognito: Bool?
    public var tabs: [Tab]
    public var left: Double?
    public var top: Double?
    public var width: Double?
    public var height: Double?

    public init(id: Int, focused: Bool, incognito: Bool? = nil, tabs: [Tab],
                left: Double? = nil, top: Double? = nil, width: Double? = nil, height: Double? = nil) {
        self.id = id; self.focused = focused; self.incognito = incognito; self.tabs = tabs
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
    public var userAgent: String?
    public var brands: [String]?
    // ack
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
             isWindowClosing, focused, incognito, windows, left, top, width, height, instance, changes, favicon, userAgent, brands, id, ok, error, browser, pid, browserPid
        case protocolVersion = "protocol"
        case extensionVersion = "extension"
    }

    public init(type: String) { self.type = type }
}

/// A command from the app to the browser.
public struct Command: Codable, Equatable, Sendable {
    public var type = "cmd"
    public var id: String
    public var op: String                // open | close | activate | snapshot
    public var url: String?
    public var tabId: Int?
    public var windowId: Int?
    public var focus: Bool?
    public var t: Double

    public static func open(_ url: String, windowId: Int? = nil) -> Command {
        Command(id: UUID().uuidString, op: "open", url: url, windowId: windowId, focus: true, t: nowMs())
    }
    public static func close(_ tabId: Int) -> Command {
        Command(id: UUID().uuidString, op: "close", tabId: tabId, t: nowMs())
    }
    public static func activate(_ tabId: Int) -> Command {
        Command(id: UUID().uuidString, op: "activate", tabId: tabId, focus: true, t: nowMs())
    }
    public static func snapshot() -> Command {
        Command(id: UUID().uuidString, op: "snapshot", t: nowMs())
    }
}

public func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
