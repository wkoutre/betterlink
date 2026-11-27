import Foundation
import Testing
@testable import TabSyncCore

struct ConnectionsTests {
    @Test func aBrowserThatIsntOpenSaysNothing() {
        let c = ExtensionConnections(running: false, sessions: [], folderVersion: "0.3.4")
        #expect(c.state == .notRunning)
        #expect(c.line(browser: "Google Chrome", helperSetUp: true) == nil)
    }

    @Test func openWithNoExtensionSaysWhatToCheck() {
        let c = ExtensionConnections(running: true, sessions: [], folderVersion: "0.3.4")
        #expect(c.state == .none)
        #expect(c.line(browser: "Google Chrome", helperSetUp: true)?.contains("Developer mode") == true)
        // Without the helper file nothing could connect; the row's own badge says Not set up.
        #expect(c.line(browser: "Google Chrome", helperSetUp: false) == nil)
    }

    @Test func connectedProfilesAreNamedInOrderWithTheirVersion() {
        let c = ExtensionConnections(running: true, sessions: [("Work", "0.3.4"), ("Claude", "0.3.4"), (nil, "0.3.4")], folderVersion: "0.3.4")
        #expect(c.state == .connected)
        #expect(c.line(browser: "Google Chrome", helperSetUp: true) == "Connected: Claude (0.3.4), Work (0.3.4), a profile (0.3.4).")
    }

    @Test func anOlderCopySaysToReloadIt() {
        let c = ExtensionConnections(running: true, sessions: [("Work", "0.3.4"), ("Personal", "0.2.0")], folderVersion: "0.3.4")
        #expect(c.state == .outdated)
        #expect(c.profiles.map(\.needsReload) == [false, true] || c.profiles.map(\.needsReload) == [true, false])
        let line = c.line(browser: "Google Chrome", helperSetUp: true) ?? ""
        #expect(line.hasPrefix("Connected: Personal (0.2.0), Work (0.3.4)."))
        #expect(line.contains("Personal (0.2.0) runs an older Tabs extension"))
    }

    @Test func aNewerCopyOrNoFolderIsNotOutdated() {
        #expect(ExtensionConnections(running: true, sessions: [("Work", "0.4.0")], folderVersion: "0.3.4").state == .connected)
        #expect(ExtensionConnections(running: true, sessions: [("Work", "0.2.0")], folderVersion: nil).state == .connected)
        #expect(ExtensionConnections(running: true, sessions: [("Work", nil)], folderVersion: "0.3.4").state == .connected)
    }

    @Test func aCheckWaitsAMinuteAfterConnectingAndBetweenChecks() {
        var p = RefreshPacer()
        func inFront(_ id: String, _ t: TimeInterval) -> Bool { p.browserInFront(id, now: t) }
        p.connected("a", now: 0)
        #expect(inFront("a", 10) == false, "its first snapshot is fresh")
        #expect(inFront("a", 61) == true)
        #expect(inFront("a", 90) == false)
        #expect(inFront("a", 122) == true)
        // A connection seen again doesn't restart its minute.
        p.connected("a", now: 200)
        #expect(inFront("a", 200) == true)
        // One never told of is checked the first time.
        #expect(inFront("b", 0) == true)
        p.keep(["b"])
        p.connected("a", now: 300)
        #expect(inFront("a", 301) == false, "forgotten, so connecting again counts as fresh")
    }

    @Test func aRefreshIsASnapshotWithoutIcons() throws {
        let j = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Command.refresh())) as! [String: Any]
        #expect(j["op"] as? String == "snapshot")
        #expect(j["icons"] as? Bool == false)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Command.snapshot())) as! [String: Any]
        #expect(plain["icons"] == nil)
    }

    @Test func aSnapshotKeepsATabsIconWhileItsAddressIsTheSame() {
        func decode(_ s: String) -> Inbound { try! JSONDecoder().decode(Inbound.self, from: Data(s.utf8)) }
        func snap(_ seq: Int, _ urlB: String) -> Inbound {
            decode(#"{"type":"snapshot","seq":\#(seq),"t":1,"windows":[{"id":1,"focused":true,"tabs":[{"id":10,"windowId":1,"index":0,"title":"A","url":"https://a/","favIconUrl":"https://a/i.png","active":true,"pinned":false,"audible":false,"status":"complete"},{"id":11,"windowId":1,"index":1,"title":"B","url":"\#(urlB)","favIconUrl":"https://b/i.png","active":false,"pinned":false,"audible":false,"status":"complete"}]}]}"#)
        }
        var s = TabStore()
        s.apply(snap(1, "https://b/"))
        s.apply(decode(#"{"type":"event","kind":"tabFavicon","seq":2,"tabId":10,"favicon":"data:image/png;base64,AA=="}"#))
        s.apply(decode(#"{"type":"event","kind":"tabFavicon","seq":3,"tabId":11,"favicon":"data:image/png;base64,BB=="}"#))
        s.apply(snap(4, "https://b/other"))
        #expect(s.tabs[10]?.favIconUrl == "data:image/png;base64,AA==")
        #expect(s.tabs[11]?.favIconUrl == "https://b/i.png", "another page: its old icon is not its icon")
    }

    /// A replacement played after a snapshot that already shows the new tab
    /// (the extension couldn't read it, so the event carries none) keeps it.
    @Test func aReplacementWithoutItsTabKeepsTheOneTheSnapshotShows() {
        func decode(_ s: String) -> Inbound { try! JSONDecoder().decode(Inbound.self, from: Data(s.utf8)) }
        var s = TabStore()
        s.apply(decode(#"{"type":"snapshot","seq":1,"t":1,"windows":[{"id":1,"focused":true,"tabs":[{"id":20,"windowId":1,"index":0,"title":"T20","url":"https://t/20","favIconUrl":"","active":true,"pinned":false,"audible":false,"status":"complete"}]}]}"#))
        s.apply(decode(#"{"type":"event","kind":"tabReplaced","seq":2,"tabId":20,"removedTabId":19}"#))
        #expect(s.tabs[20]?.title == "T20")
        #expect(s.tabs[20]?.windowId == 1)
        #expect(s.windows[1]?.tabIds == [20])
    }
}
