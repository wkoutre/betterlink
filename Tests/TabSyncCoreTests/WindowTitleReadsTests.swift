import Testing
@testable import TabSyncCore

/// A window's title is read over Accessibility at once only while its
/// browser is in front; behind another app it is read once, when a pairing
/// is about to use it, however often it changed meanwhile.
struct WindowTitleReadsTests {
    @Test func inFrontATitleIsReadAtOnce() {
        var reads = WindowTitleReads()
        let now = reads.titleChanged(browserInFront: true)
        #expect(now)
        let again = reads.pairing(readable: true)
        #expect(!again, "read already: the pairing reads it again")
    }

    @Test func behindAnotherAppItIsReadOnceAtThePairing() {
        var reads = WindowTitleReads()
        var readAtOnce = 0
        for _ in 0..<20 where reads.titleChanged(browserInFront: false) { readAtOnce += 1 }
        #expect(readAtOnce == 0)
        var atPairings = 0
        for _ in 0..<3 where reads.pairing(readable: true) { atPairings += 1 }
        #expect(atPairings == 1, "20 changes read \(atPairings) times over three pairings")
    }

    @Test func aStalledBrowserIsNotAskedAndTheChangeWaits() {
        var reads = WindowTitleReads()
        _ = reads.titleChanged(browserInFront: false)
        let stalled = reads.pairing(readable: false)
        #expect(!stalled)
        let answering = reads.pairing(readable: true)
        #expect(answering)
    }

    @Test func readingTheWholeWindowReadsItsTitle() {
        var reads = WindowTitleReads()
        _ = reads.titleChanged(browserInFront: false)
        reads.readWhole()
        let atPairing = reads.pairing(readable: true)
        #expect(!atPairing)
    }

    @Test func comingToTheFrontAChangeIsReadThenNotAgainAtThePairing() {
        var reads = WindowTitleReads()
        _ = reads.titleChanged(browserInFront: false)
        let inFront = reads.titleChanged(browserInFront: true)
        #expect(inFront)
        let atPairing = reads.pairing(readable: true)
        #expect(!atPairing)
    }

    @Test func nothingChangedNothingIsRead() {
        var reads = WindowTitleReads()
        let atPairing = reads.pairing(readable: true)
        #expect(!atPairing)
    }
}
