import Foundation
import Testing
@testable import TabSyncCore

@Suite struct PublishPacerTests {
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
