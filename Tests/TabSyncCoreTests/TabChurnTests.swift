import Foundation
import Testing
@testable import TabSyncCore

/// A window of 56 tabs, each changing its title twice a second, is 112
/// messages a second. Each was handed to the app as it came (a hop to the main
/// thread with every browser's lists, sorted and copied, and a pass over every
/// tab for the saved links' held tabs), while what tabs show is drawn only
/// every 2 s with another app in front (`PublishPacer`). A hub that holds what
/// tabs show hands on the first such change and then nothing more of the kind
/// until the app collects the lists, which it does when it publishes them.
@Suite(.serialized) struct TabChurnTests {
    static let tabs = 56

    @Test func titlesChurningAcross56TabsAreHandedOnOncePerCollect() throws {
        let host = try FakeHost()
        defer { host.close() }
        let handed = Counter()
        let hub = SyncHub(directory: host.dir, holdingContent: true, onChange: { _ in handed.add() })
        hub.start()
        try host.accept()
        host.send([#"{"type":"host","browser":"Chrome","pid":2,"browserPid":3}"#, Self.snapshot()])
        try wait(hub) { $0.first?.store.tabCount == Self.tabs }
        // The app publishes the snapshot at once (PublishPacer), and so collects it.
        _ = hub.collect()
        let settled = handed.value

        // The first title change is handed on: the app schedules its publish.
        var seq = 1
        func title(_ i: Int, _ text: String) -> String {
            seq += 1
            return Self.updated(seq: seq, tab: 100 + i % Self.tabs, title: text)
        }
        let title0 = title(0, "first")
        host.send([title0])
        try wait(hub) { $0.first?.store.tabs[100]?.title == "first" }
        #expect(handed.value == settled + 1)

        // Ten seconds of churn: 1120 more titles, nothing more handed on, and
        // none of them read until the app collects: then only each tab's
        // newest, whatever it decodes to the same lists as reading them all.
        let churn = (1...1120).map { title($0, "change \($0)") }
        let decodedBefore = hub.decodeCount, linesBefore = hub.lineCount
        host.send(churn)
        try wait(hub) { _ in hub.lineCount == linesBefore + churn.count }
        #expect(handed.value == settled + 1, "\(handed.value - settled) handed on for 1121 title changes")
        #expect(hub.decodeCount == decodedBefore, "\(hub.decodeCount - decodedBefore) of 1120 held titles decoded before the publish")

        // The app publishes: it takes the newest lists, and the next title is
        // handed on again.
        let collected = hub.collect()
        #expect(hub.decodeCount - decodedBefore <= Self.tabs, "\(hub.decodeCount - decodedBefore) decodes for 1120 titles across \(Self.tabs) tabs")
        #expect(collected.first?.store.tabs[100 + 1120 % Self.tabs]?.title == "change 1120")
        #expect(collected.first?.store == reference(sent: [Self.snapshot(), title0] + churn))
        host.send([title(7, "after the publish")])
        try wait(hub) { $0.first?.store.lastSeq == seq }
        #expect(handed.value == settled + 2)

        // A tab's address is for the saved links' held tabs at once, held or
        // not; and a switch goes on at once (PublishPacer).
        seq += 1
        host.send([Self.updated(seq: seq, tab: 103, title: "moved on", url: "https://elsewhere.example/")])
        try wait(hub) { $0.first?.store.lastSeq == seq }
        #expect(handed.value == settled + 3)
        seq += 1
        host.send([#"{"type":"event","kind":"tabActivated","seq":\#(seq),"tabId":104,"windowId":1}"#])
        try wait(hub) { $0.first?.store.lastSeq == seq }
        #expect(handed.value == settled + 4)
    }

    /// Held titles are read before whatever comes after them, an icon the
    /// app has is kept through them, and titles that aren't numbered one
    /// after another are read one by one: the lists are those of reading
    /// every line in order.
    @Test func heldTitlesLeaveTheListsAsReadingEveryLineWould() throws {
        let host = try FakeHost()
        defer { host.close() }
        let handed = Counter()
        let hub = SyncHub(directory: host.dir, holdingContent: true, onChange: { _ in handed.add() })
        hub.start()
        try host.accept()
        var sent = [Self.snapshot()]
        host.send(sent)
        try wait(hub) { $0.first?.store.tabCount == Self.tabs }
        _ = hub.collect()

        var seq = 1
        func line(_ l: String) -> String { sent.append(l); return l }
        func next() -> Int { seq += 1; return seq }
        let icon = #"{"type":"event","kind":"tabFavicon","seq":\#(next()),"t":1,"tabId":105,"favicon":"data:image/png;base64,AAAA"}"#
        let titles = (0..<300).map { Self.updated(seq: next(), tab: 100 + $0 % Self.tabs, title: "t\($0)") }
        host.send([line(icon)] + titles.map(line))
        try wait(hub) { _ in hub.lineCount == sent.count }
        let handedBefore = handed.value
        let activated = #"{"type":"event","kind":"tabActivated","seq":\#(next()),"tabId":105,"windowId":1}"#
        host.send([line(activated)])
        try wait(hub) { $0.first?.store.lastSeq == seq }
        #expect(handed.value == handedBefore + 1)
        #expect(hub.current.first?.store == reference(sent: sent))
        #expect(hub.current.first?.store.tabs[105]?.favIconUrl == "data:image/png;base64,AAAA")
        _ = hub.collect()

        // The first title is handed on, then a gap: one title never came.
        host.send([line(Self.updated(seq: next(), tab: 100, title: "handed"))])
        try wait(hub) { $0.first?.store.lastSeq == seq }
        _ = next()
        let gapped = (0..<20).map { Self.updated(seq: next(), tab: 100 + $0, title: "after the gap \($0)") }
        host.send(gapped.map(line))
        try wait(hub) { _ in hub.lineCount == sent.count }
        #expect(hub.collect().first?.store == reference(sent: sent))
    }

    /// A profile not found within a minute (its extension storage is written
    /// a moment after the extension starts) is one this browser's folder
    /// doesn't have: it is looked for again as seldom as a found one, not
    /// every 5 s for as long as the browser runs.
    @Test func aProfileNotFoundIsLookedForLessOftenAfterAMinute() {
        #expect(ProfileLocator.lookAgain(found: false, lookingFor: 0) == 5)
        #expect(ProfileLocator.lookAgain(found: false, lookingFor: 59) == 5)
        #expect(ProfileLocator.lookAgain(found: false, lookingFor: 60) == 30)
        #expect(ProfileLocator.lookAgain(found: true, lookingFor: 0) == 30)
    }

    /// The terminal view and the e2e test see every change as it comes.
    @Test func aHubThatHoldsNothingHandsOnEveryChange() throws {
        let host = try FakeHost()
        defer { host.close() }
        let handed = Counter()
        let hub = SyncHub(directory: host.dir, onChange: { _ in handed.add() })
        hub.start()
        try host.accept()
        host.send([Self.snapshot()])
        try wait(hub) { $0.first?.store.tabCount == Self.tabs }
        for seq in 2...4 {
            let before = handed.value
            host.send([Self.updated(seq: seq, tab: 100, title: "t\(seq)")])
            try wait(hub) { $0.first?.store.lastSeq == seq }
            #expect(handed.value == before + 1)
        }
    }

    // MARK: - Helpers

    static func tab(_ id: Int, index: Int, title: String, url: String? = nil, active: Bool = false) -> String {
        #"{"id":\#(id),"windowId":1,"index":\#(index),"title":"\#(title)","url":"\#(url ?? "https://t.example/\(id)")","favIconUrl":"","active":\#(active),"pinned":false,"audible":false,"muted":false,"status":"complete"}"#
    }

    static func snapshot() -> String {
        let tabs = (0..<Self.tabs).map { tab(100 + $0, index: $0, title: "Tab \($0)", active: $0 == 0) }.joined(separator: ",")
        return #"{"type":"snapshot","seq":1,"t":1,"windows":[{"id":1,"focused":false,"tabs":[\#(tabs)]}]}"#
    }

    static func updated(seq: Int, tab id: Int, title: String, url: String? = nil) -> String {
        #"{"type":"event","kind":"tabUpdated","seq":\#(seq),"t":1,"tab":\#(tab(id, index: id - 100, title: title, url: url)),"changes":["\#(url == nil ? "title" : "url")"]}"#
    }

    /// The tab lists from reading every line in order, as the extension sent them.
    func reference(sent lines: [String]) -> TabStore {
        var store = TabStore()
        for l in lines { store.apply(try! JSONDecoder().decode(Inbound.self, from: Data(l.utf8))) }
        return store
    }

    /// Waits for the hub to have taken in what was sent. What it hands on is
    /// handed on in the same turn of its queue, so it is counted by then.
    func wait(_ hub: SyncHub, until done: ([BrowserSession]) -> Bool) throws {
        let deadline = Date().addingTimeInterval(10)
        while !done(hub.current) {
            guard Date() < deadline else { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Stands in for betterlink-tabhost: a socket in a folder of its own, which
/// the hub finds and connects to, and lines written to it.
final class FakeHost {
    let dir: String
    private let listener: Int32
    private var client: Int32 = -1

    init() throws {
        // Short: a socket's path has room for about 100 bytes.
        dir = "/tmp/bl-churn-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array("\(dir)/chrome-1.sock".utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in raw.copyBytes(from: path); raw[path.count] = 0 }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard listener >= 0, bound == 0, listen(listener, 1) == 0 else { throw CancellationError() }
    }

    /// Blocks until the hub has connected.
    func accept() throws {
        client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { throw CancellationError() }
    }

    func send(_ lines: [String]) {
        let data = Data(lines.map { $0 + "\n" }.joined().utf8)
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(client, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    func close() {
        if client >= 0 { Darwin.close(client) }
        Darwin.close(listener)
        try? FileManager.default.removeItem(atPath: dir)
    }
}
