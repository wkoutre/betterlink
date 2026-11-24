import Foundation
import Testing
@testable import TabSyncCore

struct CommandTests {
    func json(_ c: Command) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
    }
    func decode(_ s: String) -> Inbound { try! JSONDecoder().decode(Inbound.self, from: Data(s.utf8)) }

    @Test func eachCommandCarriesOnlyWhatItsOpReads() {
        let move = json(.move(7, to: 2))
        #expect(move["op"] as? String == "move")
        #expect(move["tabId"] as? Int == 7)
        #expect(move["index"] as? Int == 2)
        #expect(move["windowId"] == nil)
        #expect(json(.move(7, to: 0, windowId: 3))["windowId"] as? Int == 3)

        let mute = json(.mute(7, true))
        #expect(mute["op"] as? String == "mute")
        #expect(mute["muted"] as? Bool == true)
        #expect(json(.mute(7, false))["muted"] as? Bool == false)

        #expect(json(.duplicate(7))["op"] as? String == "duplicate")
        #expect(json(.reload(7))["op"] as? String == "reload")
        #expect(json(.newWindow(with: 7))["op"] as? String == "newWindow")

        let nav = json(.navigate(7, to: "https://home.example/"))
        #expect(nav["op"] as? String == "navigate")
        #expect(nav["url"] as? String == "https://home.example/")
        #expect(nav["focus"] as? Bool == true)

        let many = json(.close([1, 2, 3]))
        #expect(many["op"] as? String == "closeMany")
        #expect(many["tabIds"] as? [Int] == [1, 2, 3])
        #expect(many["tabId"] == nil)
    }

    @Test func theOriginalCommandsKeepTheirShape() {
        let open = json(.open("https://a.example/", windowId: 4))
        #expect(open["type"] as? String == "cmd")
        #expect(open["op"] as? String == "open")
        #expect(open["windowId"] as? Int == 4)
        #expect(open["focus"] as? Bool == true)
        #expect(json(.close(9))["op"] as? String == "close")
        #expect(json(.activate(9))["focus"] as? Bool == true)
        #expect(json(.snapshot())["op"] as? String == "snapshot")
        #expect(Command.open("https://a.example/").id != Command.open("https://a.example/").id)
    }

    /// The Swift list and the extension's list (bridge.js OPS) are the same.
    @Test func everyOpTheExtensionListsIsKnownHere() throws {
        let here = URL(fileURLWithPath: #filePath)
        let bridge = here.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("browser-extension/bridge.js")
        let source = try String(contentsOf: bridge, encoding: .utf8)
        let line = try #require(source.split(separator: "\n").first { $0.hasPrefix("export const OPS = ") })
        let listed = line.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
        #expect(Set(listed) == Set(Command.Op.allCases.map(\.rawValue)))
    }

    @Test func anOlderExtensionRunsOnlyTheOriginalCommands() {
        var s = BrowserSession(socketPath: "/a")
        #expect(s.can(.open) && s.can(.close) && s.can(.activate) && s.can(.snapshot))
        #expect(!s.can(.mute) && !s.can(.move))
        // 0.1 says nothing about what it runs.
        s.greet(decode(#"{"type":"hello","protocol":1,"extension":"0.1.0","brands":["Google Chrome"],"instance":"betterlink-instance-x"}"#))
        #expect(s.extensionVersion == "0.1.0")
        #expect(s.instance == "betterlink-instance-x")
        #expect(!s.can(.mute))
        // 0.2 lists them.
        s.greet(decode(#"{"type":"hello","protocol":1,"extension":"0.2.0","ops":["snapshot","open","close","activate","move","mute"]}"#))
        #expect(s.can(.mute) && s.can(.move))
        #expect(!s.can(.duplicate))
    }

    @Test func anAckNamesTheTabItsCommandMade() {
        let ack = decode(#"{"type":"ack","id":"c1","ok":true,"t":5,"tabId":99}"#)
        #expect(ack.id == "c1")
        #expect(ack.tabId == 99)
    }

    @Test func aTabFromAnOlderExtensionStillDecodesAndIsNotMuted() {
        let old = decode(#"{"type":"event","kind":"tabCreated","seq":1,"tab":{"id":1,"windowId":2,"index":0,"title":"T","url":"https://t/","favIconUrl":"","active":true,"pinned":false,"audible":true,"status":"complete"}}"#)
        #expect(old.tab?.muted == false)
        #expect(old.tab?.audible == true)
        let new = decode(#"{"type":"event","kind":"tabUpdated","seq":2,"tab":{"id":1,"windowId":2,"index":0,"title":"T","url":"https://t/","favIconUrl":"","active":true,"pinned":false,"audible":true,"muted":true,"status":"complete"},"changes":["mutedInfo"]}"#)
        #expect(new.tab?.muted == true)
        // A tab with only its ids is still a tab.
        #expect(decode(#"{"type":"event","kind":"tabCreated","seq":3,"tab":{"id":5,"windowId":2}}"#).tab?.id == 5)
    }

    @Test func muteReachesTheStoreThroughTheNormalUpdate() {
        var store = TabStore()
        store.apply(decode(#"{"type":"snapshot","seq":1,"windows":[{"id":2,"focused":true,"tabs":[{"id":1,"windowId":2,"index":0,"title":"T","url":"https://t/","audible":true}]}]}"#))
        #expect(store.tabs[1]?.muted == false)
        store.apply(decode(#"{"type":"event","kind":"tabUpdated","seq":2,"tab":{"id":1,"windowId":2,"index":0,"title":"T","url":"https://t/","audible":true,"muted":true},"changes":["mutedInfo"]}"#))
        #expect(store.tabs[1]?.muted == true)
    }
}
