import Foundation
import Testing
@testable import TabSyncCore

struct TabStoreTests {
    func decode(_ s: String) -> Inbound { try! JSONDecoder().decode(Inbound.self, from: Data(s.utf8)) }

    func seeded() -> TabStore {
        var s = TabStore()
        s.apply(decode(#"{"type":"snapshot","seq":1,"t":1,"windows":[{"id":1,"focused":true,"tabs":[{"id":10,"windowId":1,"index":0,"title":"A","url":"https://a/","favIconUrl":"","active":true,"pinned":false,"audible":false,"status":"complete"},{"id":11,"windowId":1,"index":1,"title":"B","url":"https://b/","favIconUrl":"","active":false,"pinned":false,"audible":false,"status":"complete"}]}]}"#))
        return s
    }
    func ids(_ s: TabStore, _ w: Int = 1) -> [Int] { s.windows[w]?.tabIds ?? [] }
    func tabJSON(_ id: Int, _ w: Int, _ i: Int, active: Bool = false) -> String {
        #"{"id":\#(id),"windowId":\#(w),"index":\#(i),"title":"T\#(id)","url":"https://t/\#(id)","favIconUrl":"","active":\#(active),"pinned":false,"audible":false,"status":"loading"}"#
    }

    @Test func snapshotLoadsInTabStripOrder() {
        let s = seeded()
        #expect(ids(s) == [10, 11])
        #expect(s.orderedWindows.first?.tabs.map(\.title) == ["A", "B"])
    }

    @Test func createdInsertsAtIndexAndActivates() {
        var s = seeded()
        #expect(s.apply(decode(#"{"type":"event","kind":"tabCreated","seq":2,"tab":\#(tabJSON(12, 1, 1, active: true))}"#)) == .applied)
        #expect(ids(s) == [10, 12, 11])
        #expect(s.tabs[10]?.active == false)
        #expect(s.tabs[12]?.active == true)
    }

    @Test func removedMovedActivated() {
        var s = seeded()
        s.apply(decode(#"{"type":"event","kind":"tabMoved","seq":2,"tabId":10,"windowId":1,"fromIndex":0,"toIndex":1}"#))
        #expect(ids(s) == [11, 10])
        s.apply(decode(#"{"type":"event","kind":"tabActivated","seq":3,"tabId":11,"windowId":1}"#))
        #expect(s.tabs[11]?.active == true)
        #expect(s.tabs[10]?.active == false)
        s.apply(decode(#"{"type":"event","kind":"tabRemoved","seq":4,"tabId":11,"windowId":1,"isWindowClosing":false}"#))
        #expect(ids(s) == [10])
        #expect(s.tabs[11] == nil)
    }

    @Test func detachAttachMovesBetweenWindows() {
        var s = seeded()
        s.apply(decode(#"{"type":"event","kind":"windowCreated","seq":2,"windowId":2,"focused":false}"#))
        s.apply(decode(#"{"type":"event","kind":"tabDetached","seq":3,"tabId":11,"windowId":1,"fromIndex":1}"#))
        s.apply(decode(#"{"type":"event","kind":"tabAttached","seq":4,"tabId":11,"windowId":2,"toIndex":0}"#))
        #expect(ids(s, 1) == [10])
        #expect(ids(s, 2) == [11])
        #expect(s.tabs[11]?.windowId == 2)
    }

    @Test func updatedKeepsPosition() {
        var s = seeded()
        s.apply(decode(#"{"type":"event","kind":"tabUpdated","seq":2,"tab":{"id":10,"windowId":1,"index":0,"title":"A2","url":"https://a2/","favIconUrl":"","active":true,"pinned":false,"audible":false,"status":"complete"},"changes":["title"]}"#))
        #expect(ids(s) == [10, 11])
        #expect(s.tabs[10]?.title == "A2")
    }

    @Test func replacedSwapsIdInPlace() {
        var s = seeded()
        s.apply(decode(#"{"type":"event","kind":"tabReplaced","seq":2,"tabId":20,"removedTabId":10,"tab":\#(tabJSON(20, 1, 0))}"#))
        #expect(ids(s) == [20, 11])
        #expect(s.tabs[10] == nil)
    }

    @Test func windowRemovedDropsItsTabs() {
        var s = seeded()
        s.apply(decode(#"{"type":"event","kind":"windowRemoved","seq":2,"windowId":1}"#))
        #expect(s.windows.isEmpty)
        #expect(s.tabCount == 0)
    }

    @Test func sequenceGapAsksForSnapshotAndStaleEventsAreIgnored() {
        var s = seeded()
        #expect(s.apply(decode(#"{"type":"event","kind":"tabActivated","seq":5,"tabId":11,"windowId":1}"#)) == .needsSnapshot)
        #expect(s.apply(decode(#"{"type":"event","kind":"tabActivated","seq":3,"tabId":11,"windowId":1}"#)) == .ignored)
    }

    @Test func eventsBeforeFirstSnapshotAreIgnored() {
        var s = TabStore()
        #expect(s.apply(decode(#"{"type":"event","kind":"tabRemoved","seq":1,"tabId":1,"windowId":1}"#)) == .ignored)
    }

    @Test func nativeFramingRoundTripsAcrossChunkBoundaries() {
        let a = Data(#"{"a":1}"#.utf8), b = Data(#"{"b":"two"}"#.utf8)
        let wire = NativeFraming.encode(a) + NativeFraming.encode(b)
        var d = NativeFraming.Decoder()
        var got: [Data] = []
        for byte in wire { got += d.feed(Data([byte])) }
        #expect(got == [a, b])
    }

    @Test func lineDecoderSplitsOnNewlines() {
        var d = LineDecoder()
        #expect(d.feed(Data("{\"a\":1}\n{\"b\"".utf8)) == [Data("{\"a\":1}".utf8)])
        #expect(d.feed(Data(":2}\n".utf8)) == [Data("{\"b\":2}".utf8)])
    }

    @Test func commandEncodesWhatTheExtensionExpects() throws {
        let c = Command.open("https://x.test/")
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        #expect(obj["type"] as? String == "cmd")
        #expect(obj["op"] as? String == "open")
        #expect(obj["url"] as? String == "https://x.test/")
    }

    @Test func registrationWritesManifestOnlyIntoAnExistingBrowserFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bl-tabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        // Browser never run: its folder is absent, so nothing is created.
        #expect(throws: (any Error).self) { try HostRegistration.install(dataFolder: "Google/Chrome", hostPath: "/x/host", home: home) }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Library/Application Support/Google/Chrome").path))

        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Google/Chrome"), withIntermediateDirectories: true)
        #expect(HostRegistration.state(dataFolder: "Google/Chrome", hostPath: "/x/host", home: home) == .notInstalled)
        try HostRegistration.install(dataFolder: "Google/Chrome", hostPath: "/x/host", home: home)
        #expect(HostRegistration.state(dataFolder: "Google/Chrome", hostPath: "/x/host", home: home) == .installed)
        #expect(HostRegistration.state(dataFolder: "Google/Chrome", hostPath: "/moved/host", home: home) == .stale(path: "/x/host"))

        let url = HostRegistration.manifestURL(dataFolder: "Google/Chrome", home: home)
        #expect(url.path.hasSuffix("Google/Chrome/NativeMessagingHosts/com.wkoutre.betterlink.tabs.json"))
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(obj["allowed_origins"] as? [String] == ["chrome-extension://gjjllnebeeegbipppiclhlomdppbnljh/"])
        #expect(obj["type"] as? String == "stdio")

        try HostRegistration.uninstall(dataFolder: "Google/Chrome", home: home)
        #expect(HostRegistration.state(dataFolder: "Google/Chrome", hostPath: "/x/host", home: home) == .notInstalled)
    }

    @Test func aRegistrationForAnotherExtensionIdIsStale() throws {
        // Written before the extension took its Chrome Web Store id: the path is
        // right, but the browser would refuse the extension that asks today.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bl-tabs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let url = HostRegistration.manifestURL(dataFolder: "Google/Chrome", home: home)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old: [String: Any] = ["name": HostRegistration.hostName, "path": "/x/host", "type": "stdio",
                                  "allowed_origins": ["chrome-extension://nakiifbonhngpkpekakimjfgkbbbnjoe/"]]
        try JSONSerialization.data(withJSONObject: old).write(to: url)
        #expect(HostRegistration.state(dataFolder: "Google/Chrome", hostPath: "/x/host", home: home) == .stale(path: "/x/host"))

        try HostRegistration.install(dataFolder: "Google/Chrome", hostPath: "/x/host", home: home)
        #expect(HostRegistration.state(dataFolder: "Google/Chrome", hostPath: "/x/host", home: home) == .installed)
    }

    @Test func extensionManifestPinsTheRegisteredId() throws {
        // The id in HostRegistration must be the one Chrome derives from the manifest key.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let m = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("browser-extension/manifest.json"))) as! [String: Any]
        let der = try #require(Data(base64Encoded: m["key"] as! String))
        #expect(chromeExtensionId(publicKeyDER: der) == HostRegistration.extensionId)
    }
}

/// Chrome's id: the first 128 bits of SHA-256 of the DER public key, as a-p.
private func chromeExtensionId(publicKeyDER: Data) -> String {
    let hex = sha256Hex(publicKeyDER).prefix(32)
    return String(hex.map { Character(UnicodeScalar(UInt8(97) + UInt8($0.hexDigitValue!))) })
}

#if canImport(CryptoKit)
import CryptoKit
private func sha256Hex(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
#else
private func sha256Hex(_ d: Data) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/sha256sum")
    let i = Pipe(), o = Pipe(); p.standardInput = i; p.standardOutput = o
    try! p.run(); i.fileHandleForWriting.write(d); try! i.fileHandleForWriting.close(); p.waitUntilExit()
    return String(String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.prefix(64))
}
#endif

struct FaviconStoreTests {
    func decode(_ s: String) -> Inbound { try! JSONDecoder().decode(Inbound.self, from: Data(s.utf8)) }

    @Test func inlineIconSticksUntilTheBrowserReportsANewOne() {
        var s = TabStore()
        s.apply(decode(#"{"type":"snapshot","seq":1,"windows":[{"id":1,"focused":true,"tabs":[{"id":10,"windowId":1,"index":0,"title":"A","url":"https://a/","favIconUrl":"https://a/i.png","active":true,"pinned":false,"audible":false,"status":"complete"}]}]}"#))
        s.apply(decode(#"{"type":"event","kind":"tabFavicon","seq":2,"tabId":10,"favicon":"data:image/png;base64,AAAA"}"#))
        #expect(s.tabs[10]?.favIconUrl == "data:image/png;base64,AAAA")
        s.apply(decode(#"{"type":"event","kind":"tabUpdated","seq":3,"changes":["title"],"tab":{"id":10,"windowId":1,"index":0,"title":"A2","url":"https://a/","favIconUrl":"https://a/i.png","active":true,"pinned":false,"audible":false,"status":"complete"}}"#))
        #expect(s.tabs[10]?.favIconUrl == "data:image/png;base64,AAAA")
        #expect(s.tabs[10]?.title == "A2")
        s.apply(decode(#"{"type":"event","kind":"tabUpdated","seq":4,"changes":["favIconUrl"],"tab":{"id":10,"windowId":1,"index":0,"title":"A2","url":"https://b/","favIconUrl":"https://b/i.png","active":true,"pinned":false,"audible":false,"status":"loading"}}"#))
        #expect(s.tabs[10]?.favIconUrl == "https://b/i.png")
    }
}

/// The browser's own word for each window (`chrome.windows`: normal, popup,
/// app), passed on by the extension since 0.3.2.
struct WindowTypeTests {
    func decode(_ s: String) -> Inbound { try! JSONDecoder().decode(Inbound.self, from: Data(s.utf8)) }
    private func tab(_ id: Int, _ w: Int, _ title: String) -> String {
        #"{"id":\#(id),"windowId":\#(w),"index":0,"title":"\#(title)","url":"https://t/\#(id)","active":true}"#
    }
    /// A normal window, an extension's palette (a popup), and a window from an
    /// extension that sends no type.
    private func seeded() -> TabStore {
        var s = TabStore()
        s.apply(decode(#"{"type":"snapshot","seq":1,"windows":["# + [
            #"{"id":1,"focused":true,"windowType":"normal","left":0,"top":31,"width":748,"height":1259,"tabs":[\#(tab(10, 1, "Inbox"))]}"#,
            #"{"id":2,"focused":false,"windowType":"popup","left":900,"top":31,"width":400,"height":600,"tabs":[\#(tab(20, 2, "Palette"))]}"#,
            #"{"id":3,"focused":false,"left":0,"top":31,"width":748,"height":1259,"tabs":[\#(tab(30, 3, "Docs"))]}"#,
        ].joined(separator: ",") + "]}"))
        return s
    }

    @Test func eachWindowsTypeArrivesInTheSnapshotAndWhenAWindowOpens() {
        var s = seeded()
        #expect(s.windows[1]?.type == "normal")
        #expect(s.windows[2]?.type == "popup")
        #expect(s.windows[3]?.type == nil)
        s.apply(decode(#"{"type":"event","kind":"windowCreated","seq":2,"windowId":4,"focused":true,"windowType":"app"}"#))
        #expect(s.windows[4]?.type == "app")
        // A tab of a window whose own event hasn't come yet.
        s.apply(decode(#"{"type":"event","kind":"tabCreated","seq":3,"tab":\#(tab(50, 5, "New"))}"#))
        #expect(s.windows[5]?.type == nil)
        s.apply(decode(#"{"type":"event","kind":"windowCreated","seq":4,"windowId":5,"focused":true,"windowType":"popup"}"#))
        #expect(s.windows[5]?.type == "popup" && s.windows[5]?.tabIds == [50])
    }

    @Test func onlyAPopupOrAnAppWindowIsNotNormal() {
        let s = seeded()
        #expect(s.windows[1]?.isNormal == true)
        #expect(s.windows[2]?.isNormal == false)
        // An extension older than 0.3.2 says nothing: normal, as before.
        #expect(s.windows[3]?.isNormal == true)
        var app = s.windows[1]!
        app.type = "app"
        #expect(!app.isNormal)
    }

    @Test func theNormalWindowsOnlyLeavesOutPopupsAndTheirTabs() {
        let all = seeded(), normal = all.normalWindowsOnly
        #expect(normal.windowOrder == [1, 3])
        #expect(normal.windows.keys.sorted() == [1, 3])
        #expect(normal.tabs.keys.sorted() == [10, 30])
        #expect(normal.hasSnapshot && normal.lastSeq == all.lastSeq)
        // The store itself still holds every window.
        #expect(all.windowOrder == [1, 2, 3] && all.tabCount == 3)
    }

    /// A window on screen exactly where the extension reports a popup, with
    /// its title: handed the normal windows only, the pairing has nothing to
    /// give it, and the normal window keeps its own.
    @Test func aPopupIsNeverTheBrowserWindowBesideASidebar() {
        var session = BrowserSession(socketPath: "/a")
        session.browserPid = 7
        session.store = seeded()
        let palette = WindowPairing.Window(id: 100, pid: 7, app: "Brave Browser", frame: WindowBounds(left: 900, top: 31, width: 400, height: 600), title: "Palette")
        let inbox = WindowPairing.Window(id: 101, pid: 7, app: "Brave Browser", frame: WindowBounds(left: 0, top: 31, width: 748, height: 1259), title: "Inbox - Brave")
        var p = WindowPairing()
        let found = p.update([palette, inbox], in: [session.normalWindowsOnly])
        #expect(found[100] == .unseen)
        #expect(found[101] == .window(.init(session: "/a", windowId: 1)))
    }
}

struct ProfileTests {
    private func snapshot(_ wins: [SnapshotWindow]) -> Inbound {
        var m = Inbound(type: "snapshot"); m.seq = 1; m.windows = wins; return m
    }

    @Test func windowBoundsArriveInTheSnapshotAndFollowMoves() {
        var s = TabStore()
        s.apply(snapshot([SnapshotWindow(id: 1, focused: true, tabs: [], left: 0, top: 31, width: 748, height: 1259)]))
        #expect(s.windows[1]?.bounds == WindowBounds(left: 0, top: 31, width: 748, height: 1259))
        var e = Inbound(type: "event"); e.kind = "windowBounds"; e.seq = 2; e.windowId = 1
        e.left = 1028; e.top = 31; e.width = 748; e.height = 1259
        s.apply(e)
        #expect(s.windows[1]?.bounds?.left == 1028)
    }

    @Test func theProfileFolderIsFoundByTheExtensionsStoredId() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bl-prof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for (profile, token) in [("Default", "betterlink-instance-aaa"), ("Profile 1", "betterlink-instance-bbb")] {
            let dir = root.appendingPathComponent(profile).appendingPathComponent("Local Extension Settings")
                .appendingPathComponent(HostRegistration.extensionId)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("\u{1}\u{0}junk\"betterlinkInstance\"\"\(token)\"".utf8).write(to: dir.appendingPathComponent("000003.log"))
        }
        #expect(ProfileLocator.directory(instance: "betterlink-instance-bbb", dataFolder: root) == "Profile 1")
        #expect(ProfileLocator.directory(instance: "betterlink-instance-aaa", dataFolder: root) == "Default")
        #expect(ProfileLocator.directory(instance: "betterlink-instance-zzz", dataFolder: root) == nil)
    }
}
