import Testing
@testable import TabSyncCore

struct TabTransferTests {
    @Test func onlyWebPagesAndFilesCanBeSent() {
        #expect(TabTransfer.canSend("https://example.com/a"))
        #expect(TabTransfer.canSend("HTTP://example.com"))
        #expect(TabTransfer.canSend("file:///Users/me/a.pdf"))
        #expect(!TabTransfer.canSend("chrome://settings"))
        #expect(!TabTransfer.canSend("brave://newtab"))
        #expect(!TabTransfer.canSend("about:blank"))
        #expect(!TabTransfer.canSend(""))
        #expect(!TabTransfer.canSend("javascript:alert(1)"))
        #expect(!TabTransfer.canSend("https://example.com/\n--flag"))
    }

    @Test func neverToItselfAndNeverOutOfAPrivateWindow() {
        #expect(TabTransfer.canSend(from: "/a.sock", to: "/b.sock", incognito: false))
        #expect(!TabTransfer.canSend(from: "/a.sock", to: "/a.sock", incognito: false))
        #expect(!TabTransfer.canSend(from: "/a.sock", to: "/b.sock", incognito: true))
    }

    @Test func theTabClosesOnlyWhenTheOpenSaysYes() {
        var t = TabTransfer()
        let source = TabTransfer.Source(socketPath: "/a.sock", tabId: 7)
        t.started(command: "c1", closing: source)
        t.started(command: "c2", closing: .init(socketPath: "/a.sock", tabId: 8))
        #expect(t.answered(command: "other", ok: true) == nil)
        #expect(t.answered(command: "c1", ok: true) == source)
        // Answered once: a repeat closes nothing.
        #expect(t.answered(command: "c1", ok: true) == nil)
        // A failed open keeps the tab.
        #expect(t.answered(command: "c2", ok: false) == nil)
        #expect(t.pending.isEmpty)
    }

    @Test func aSendThatNeverAnswersKeepsTheTab() {
        var t = TabTransfer()
        t.started(command: "c1", closing: .init(socketPath: "/a.sock", tabId: 7))
        t.gaveUp(command: "c1")
        #expect(t.answered(command: "c1", ok: true) == nil)
    }

    @Test func sessionsThatReadTheSameAreNumbered() {
        let labels = TabTransfer.labels([
            (id: "/s/b", base: "Google Chrome"),
            (id: "/s/a", base: "Google Chrome"),
            (id: "/s/c", base: "Work (Google Chrome)"),
            (id: "/s/d", base: "Brave Browser"),
        ])
        #expect(labels["/s/a"] == "Google Chrome 1")
        #expect(labels["/s/b"] == "Google Chrome 2")
        #expect(labels["/s/c"] == "Work (Google Chrome)")
        #expect(labels["/s/d"] == "Brave Browser")
        #expect(Set(labels.values).count == 4)
    }
}
