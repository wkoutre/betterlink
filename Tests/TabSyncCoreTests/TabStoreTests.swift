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

    @Test func theFrontWindowIsMatchedToItsProfileByFrame() {
        var a = BrowserSession(socketPath: "/a"), b = BrowserSession(socketPath: "/b")
        a.store.apply(snapshot([SnapshotWindow(id: 1, focused: false, tabs: [], left: 0, top: 31, width: 748, height: 1259)]))
        b.store.apply(snapshot([SnapshotWindow(id: 7, focused: true, tabs: [], left: 1028, top: 31, width: 748, height: 1259)]))
        let front = WindowBounds(left: 1029, top: 31, width: 747, height: 1259)
        #expect(WindowMatch.best(for: front, in: [a, b]) == WindowMatch.Hit(session: "/b", windowId: 7))
        #expect(WindowMatch.best(for: WindowBounds(left: 300, top: 200, width: 500, height: 500), in: [a, b]) == nil)
    }

    @Test func windowsOfOneProfileAtTheSameSpotAreToldApartByFocus() {
        var a = BrowserSession(socketPath: "/a"), b = BrowserSession(socketPath: "/b")
        let spot = (left: 0.0, top: 31.0, width: 748.0, height: 1259.0)
        a.store.apply(snapshot([SnapshotWindow(id: 1, focused: false, tabs: [], left: spot.left, top: spot.top, width: spot.width, height: spot.height),
                                SnapshotWindow(id: 2, focused: true, tabs: [], left: spot.left, top: spot.top, width: spot.width, height: spot.height)]))
        b.store.apply(snapshot([SnapshotWindow(id: 9, focused: false, tabs: [], left: spot.left, top: spot.top, width: spot.width, height: spot.height)]))
        let frame = WindowBounds(left: spot.left, top: spot.top, width: spot.width, height: spot.height)
        #expect(WindowMatch.front(frame: frame, in: [a, b]) == WindowMatch.Hit(session: "/a", windowId: 2))
        // Focus moves to the other profile: its extension reports its window, this one reports none (-1).
        var lose = Inbound(type: "event"); lose.kind = "windowFocused"; lose.seq = 2; lose.windowId = -1
        var gain = Inbound(type: "event"); gain.kind = "windowFocused"; gain.seq = 2; gain.windowId = 9
        a.store.apply(lose); b.store.apply(gain)
        #expect(WindowMatch.front(frame: frame, in: [a, b]) == WindowMatch.Hit(session: "/b", windowId: 9))
    }

    // MARK: - The window in front (WindowMatch.find)

    func window(_ id: Int, focused: Bool, title: String, at left: Double = 0, incognito: Bool? = nil) -> SnapshotWindow {
        SnapshotWindow(id: id, focused: focused, incognito: incognito,
                       tabs: [Tab(id: id * 10, windowId: id, title: title, url: "https://\(id).example/", active: true)],
                       left: left, top: 31, width: 748, height: 1259)
    }
    func frame(at left: Double = 0) -> WindowBounds { WindowBounds(left: left, top: 31, width: 748, height: 1259) }

    @Test func theFocusedWindowIsTheOneInFront() {
        var a = BrowserSession(socketPath: "/a")
        a.store.apply(snapshot([window(1, focused: false, title: "Inbox"), window(2, focused: true, title: "Docs")]))
        #expect(WindowMatch.find(frame: frame(), title: "Docs - Google Chrome", in: [a]) == .window(.init(session: "/a", windowId: 2)))
    }

    @Test func anIncognitoWindowTheExtensionCannotSeeShowsNoOtherWindowsTabs() {
        // The extension isn't allowed in Incognito: it reports only the regular
        // window, and "no window of mine has focus" while the Incognito one is in front.
        var a = BrowserSession(socketPath: "/a")
        a.store.apply(snapshot([window(1, focused: false, title: "Inbox")]))
        // Exactly on top of the regular window, showing another page.
        #expect(WindowMatch.find(frame: frame(), title: "Secret - Google Chrome (Incognito)", in: [a]) == .unseen)
        // Somewhere else on screen.
        #expect(WindowMatch.find(frame: frame(at: 900), title: "Inbox - Google Chrome", in: [a]) == .unseen)
    }

    @Test func withNothingFocusedTheWindowAtThisFrameWithThisTitleIsIt() {
        // betterlink's own window is in front: the browser reports no focused window.
        var a = BrowserSession(socketPath: "/a"), b = BrowserSession(socketPath: "/b")
        a.store.apply(snapshot([window(1, focused: false, title: "Inbox"), window(2, focused: false, title: "Docs", at: 800)]))
        b.store.apply(snapshot([window(9, focused: false, title: "Tracker")]))
        #expect(WindowMatch.find(frame: frame(), title: "Inbox - Google Chrome", in: [a, b]) == .window(.init(session: "/a", windowId: 1)))
        #expect(WindowMatch.find(frame: frame(), title: "Tracker - Google Chrome - Work", in: [a, b]) == .window(.init(session: "/b", windowId: 9)))
        #expect(WindowMatch.find(frame: frame(at: 801), title: "Docs - Google Chrome", in: [a, b]) == .window(.init(session: "/a", windowId: 2)))
        // Two windows at one frame with one title: no telling, so nothing.
        var c = BrowserSession(socketPath: "/c")
        c.store.apply(snapshot([window(3, focused: false, title: "Inbox")]))
        #expect(WindowMatch.find(frame: frame(), title: "Inbox - Google Chrome", in: [a, c]) == .unseen)
    }

    @Test func aPageStillLoadingIsMatchedByItsFrameAlone() {
        var a = BrowserSession(socketPath: "/a")
        a.store.apply(snapshot([window(1, focused: false, title: ""), window(2, focused: false, title: "Docs", at: 800)]))
        #expect(WindowMatch.find(frame: frame(), title: "Untitled - Google Chrome", in: [a]) == .window(.init(session: "/a", windowId: 1)))
        #expect(WindowMatch.find(frame: frame(), title: "", in: [a]) == .window(.init(session: "/a", windowId: 1)))
    }

    @Test func withoutFramesTheTitleAloneDecidesWhenOneWindowHasIt() {
        var a = BrowserSession(socketPath: "/a")
        a.store.apply(snapshot([SnapshotWindow(id: 1, focused: false, tabs: [Tab(id: 10, windowId: 1, title: "Inbox", active: true)]),
                                SnapshotWindow(id: 2, focused: false, tabs: [Tab(id: 20, windowId: 2, title: "Docs", active: true)])]))
        #expect(WindowMatch.find(frame: frame(), title: "Docs - Brave", in: [a]) == .window(.init(session: "/a", windowId: 2)))
        #expect(WindowMatch.find(frame: nil, title: "Neither", in: [a]) == .unseen)
    }

    @Test func aBrowserWithNoExtensionConnectedIsNotConnected() {
        #expect(WindowMatch.find(frame: frame(), title: "Inbox", in: []) == .notConnected)
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
