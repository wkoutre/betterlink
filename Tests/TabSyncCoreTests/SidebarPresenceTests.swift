import Testing
@testable import TabSyncCore

struct SidebarPresenceTests {
    private func decide(panel: UInt32? = 99, onScreen: [UInt32], hidden: Bool = false,
                        settled: Bool = false) -> SidebarPresence.Decision {
        SidebarPresence.decide(window: 10, panel: panel, onScreen: onScreen, hidden: hidden, attached: true, settled: settled)
    }

    @Test func aWindowOnScreenShowsItsSidebarWhateverIsInFront() {
        #expect(decide(onScreen: [1, 2, 99, 10, 3]) == .shown(rehome: false, reorder: false))
    }

    @Test func theSidebarStaysDirectlyAboveItsWindow() {
        // Left in front of another app's window by a click in it.
        #expect(decide(onScreen: [99, 1, 10]) == .shown(rehome: false, reorder: true))
        // Its window was raised past it.
        #expect(decide(onScreen: [10, 99, 1]) == .shown(rehome: false, reorder: true))
    }

    @Test func notOrderedInYet() {
        #expect(decide(panel: nil, onScreen: [10]) == .shown(rehome: false, reorder: true))
    }

    @Test func hiddenMinimizedOrFullScreenIsAway() {
        #expect(decide(onScreen: [99, 10], hidden: true) == .away)
        #expect(decide(panel: nil, onScreen: [10], hidden: true) == .away)
    }

    @Test func aWindowOnAnotherSpaceKeepsItsSidebarThereAndNeverHere() {
        #expect(decide(onScreen: [1, 2]) == .asleep)
        #expect(decide(panel: nil, onScreen: [1, 2]) == .asleep)
        #expect(decide(onScreen: [1, 2], settled: true) == .asleep)
        // The window moved to another Space: the panel is left behind here.
        #expect(decide(onScreen: [99, 1], settled: true) == .away)
        // Not while Spaces are still changing: the list may show one of the
        // two a moment longer, and a panel taken away would not come back
        // with its Space.
        #expect(decide(onScreen: [99, 1]) == .asleep)
    }

    @Test func aSidebarLeftOnAnotherSpaceComesOverOnceSpacesHaveSettled() {
        #expect(decide(onScreen: [10], settled: true) == .shown(rehome: true, reorder: true))
        #expect(decide(onScreen: [10]) == .shown(rehome: false, reorder: true))
        #expect(decide(panel: nil, onScreen: [10], settled: true) == .shown(rehome: false, reorder: true))
    }
}
