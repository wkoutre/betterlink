import Testing
@testable import TabSyncCore

struct TabMoveTests {
    // Tabs a b c d e at 0...4.
    @Test func movingRightLandsWhereItWasDropped() {
        #expect(TabMove.index(moving: 0, nextTo: 3, after: false) == 2) // a before d: b c a d e
        #expect(TabMove.index(moving: 0, nextTo: 3, after: true) == 3)  // a after d: b c d a e
        #expect(TabMove.index(moving: 1, nextTo: 4, after: true) == 4)  // b to the end
    }

    @Test func movingLeftLandsWhereItWasDropped() {
        #expect(TabMove.index(moving: 4, nextTo: 0, after: false) == 0) // e first
        #expect(TabMove.index(moving: 4, nextTo: 1, after: false) == 1) // e before b
        #expect(TabMove.index(moving: 3, nextTo: 0, after: true) == 1)  // d after a
    }

    @Test func droppingNextToItselfDoesNothing() {
        #expect(TabMove.index(moving: 2, nextTo: 2, after: false) == nil)
        #expect(TabMove.index(moving: 2, nextTo: 2, after: true) == nil)
        #expect(TabMove.index(moving: 2, nextTo: 1, after: true) == nil) // already right after b
        #expect(TabMove.index(moving: 2, nextTo: 3, after: false) == nil) // already right before d
    }
}
