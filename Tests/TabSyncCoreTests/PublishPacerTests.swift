import Foundation
import Testing
@testable import TabSyncCore

@Suite struct PublishPacerTests {
    /// Sidebars are on screen beside every browser window nearly all day. Only
    /// with a browser in front is anyone watching titles change as they change.
    @Test func whatTabsShowKeepsToTheMomentOnlyWithASidebarOnScreenAndABrowserInFront() {
        #expect(PublishPacer.interval(sidebarOnScreen: true, browserInFront: true) == 0.1)
        #expect(PublishPacer.interval(sidebarOnScreen: true, browserInFront: false) == 2)
        #expect(PublishPacer.interval(sidebarOnScreen: false, browserInFront: true) == 2)
        #expect(PublishPacer.interval(sidebarOnScreen: false, browserInFront: false) == 2)
    }

    /// Another app in front, a tab's title changing twice a second: every 2 s.
    /// The browser comes forward: the next change goes at once.
    @Test func theRateFollowsWhichAppIsInFront() {
        var p = PublishPacer(), published = 0, due: Double?
        func run(from: Int, to: Int, inFront: Bool) {
            for i in from..<to { // a change every half second
                let now = Double(i) / 2
                if let d = due, now >= d { p.published(now: d); published += 1; due = nil }
                switch p.changed(urgent: false, now: now, interval: PublishPacer.interval(sidebarOnScreen: true, browserInFront: inFront)) {
                case .now: p.published(now: now); published += 1; due = nil
                case .after(let s): due = now + s
                case .waiting: break
                }
            }
        }
        run(from: 0, to: 60, inFront: false) // 30 s
        #expect((15...16).contains(published))
        published = 0
        run(from: 60, to: 120, inFront: true)
        #expect((60...61).contains(published)) // each of the 60, and the one held back
    }

    @Test func aQuietChangeGoesAtOnce() {
        var p = PublishPacer()
        #expect(p.changed(urgent: false, now: 10, interval: 0.1) == .now)
        p.published(now: 10)
        #expect(p.changed(urgent: false, now: 10.2, interval: 0.1) == .now)
    }

    @Test func churnIsHeldToOnePerInterval() {
        var p = PublishPacer(), published = 0, due: Double?
        for i in 0..<1000 { // 1000 changes over 10 s
            let now = Double(i) / 100
            if let d = due, now >= d { p.published(now: d); published += 1; due = nil }
            switch p.changed(urgent: false, now: now, interval: 0.1) {
            case .now: p.published(now: now); published += 1; due = nil
            case .after(let s): #expect(due == nil); due = now + s
            case .waiting: #expect(due != nil)
            }
        }
        #expect((95...102).contains(published))
    }

    /// The last change is never left out.
    @Test func everyChangeIsPublishedOrWaitedFor() {
        var p = PublishPacer()
        p.published(now: 0)
        #expect(p.changed(urgent: false, now: 0.02, interval: 0.1) == .after(0.08))
        #expect(p.changed(urgent: false, now: 0.05, interval: 0.1) == .waiting)
    }

    @Test func anUrgentChangeNeverWaits() {
        var p = PublishPacer()
        p.published(now: 0)
        _ = p.changed(urgent: false, now: 0.01, interval: 1)
        #expect(p.changed(urgent: true, now: 0.02, interval: 1) == .now)
        p.published(now: 0.02)
        #expect(p.changed(urgent: false, now: 0.03, interval: 1) == .after(0.99))
    }

    /// The sidebar came into view: what waited for the slow pace goes sooner.
    @Test func aShorterIntervalIsNotHeldByALongerOne() {
        var p = PublishPacer()
        p.published(now: 0)
        #expect(p.changed(urgent: false, now: 0.5, interval: 2) == .after(1.5))
        #expect(p.changed(urgent: false, now: 0.6, interval: 0.1) == .now)
    }

    @Test func onlyWhatATabShowsIsContent() throws {
        func m(_ s: String) throws -> Inbound { try JSONDecoder().decode(Inbound.self, from: Data(s.utf8)) }
        #expect(PublishPacer.isContent(try m(#"{"type":"event","kind":"tabUpdated"}"#)))
        #expect(PublishPacer.isContent(try m(#"{"type":"event","kind":"tabFavicon"}"#)))
        for k in ["tabCreated", "tabRemoved", "tabMoved", "tabActivated", "windowFocused", "windowBounds"] {
            #expect(!PublishPacer.isContent(try m(#"{"type":"event","kind":"\#(k)"}"#)))
        }
        #expect(!PublishPacer.isContent(try m(#"{"type":"snapshot"}"#)))
    }
}
