import Testing
@testable import TabSyncCore

struct SidebarPresenceTests {
    private func decide(window: UInt32? = 10, panel: UInt32? = 99, onScreen: [UInt32], hidden: Bool = false,
                        mayRehome: Bool = false) -> SidebarPresence.Decision {
        SidebarPresence.decide(window: window, panel: panel, onScreen: onScreen, hidden: hidden, attached: true, mayRehome: mayRehome)
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

    @Test func hiddenMinimizedFullScreenOrUnknownIsAway() {
        #expect(decide(onScreen: [99, 10], hidden: true) == .away)
        #expect(decide(window: nil, onScreen: [99, 10]) == .away)
    }

    @Test func aWindowOnAnotherSpaceKeepsItsSidebarThereAndNeverHere() {
        #expect(decide(onScreen: [1, 2]) == .asleep)
        #expect(decide(panel: nil, onScreen: [1, 2]) == .asleep)
        // The window moved to another Space (or was minimized): the panel is left behind here.
        #expect(decide(onScreen: [99, 1]) == .away)
    }

    @Test func aSidebarLeftOnAnotherSpaceComesOverOnceSpacesHaveSettled() {
        #expect(decide(onScreen: [10], mayRehome: true) == .shown(rehome: true, reorder: true))
        #expect(decide(onScreen: [10]) == .shown(rehome: false, reorder: true))
        #expect(decide(panel: nil, onScreen: [10], mayRehome: true) == .shown(rehome: false, reorder: true))
    }
}
