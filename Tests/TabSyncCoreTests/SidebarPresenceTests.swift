import Testing
@testable import TabSyncCore

struct SidebarPresenceTests {
    private func decide(panel: UInt32? = 99, onScreen: [UInt32], hidden: Bool = false, attached: Bool = true,
                        settled: Bool = false) -> SidebarPresence.Decision {
        SidebarPresence.decide(window: 10, panel: panel, onScreen: onScreen, hidden: hidden, attached: attached, settled: settled)
    }

    /// Beside its window the panel lies under it, so the window's rounded
    /// corners are drawn over the sidebar. Covering the window's edge it can
    /// only be seen on top.
    @Test func besideItsWindowThePanelGoesUnderItAndCoveringItsEdgeOnTop() {
        #expect(SidebarPresence.relation(attached: true) == .below)
        #expect(SidebarPresence.relation(attached: false) == .above)
    }

    @Test func aWindowOnScreenShowsItsSidebarWhateverIsInFront() {
        #expect(decide(onScreen: [1, 2, 10, 99, 3]) == .shown(rehome: false, reorder: false))
    }

    @Test func theSidebarStaysDirectlyBelowItsWindow() {
        // Brought to the front by a click in it.
        #expect(decide(onScreen: [99, 1, 10]) == .shown(rehome: false, reorder: true))
        #expect(decide(onScreen: [99, 10]) == .shown(rehome: false, reorder: true))
        // Its window was raised past another window, which is now between them.
        #expect(decide(onScreen: [10, 1, 99]) == .shown(rehome: false, reorder: true))
    }

    @Test func aSidebarCoveringItsWindowsEdgeStaysDirectlyAboveIt() {
        #expect(decide(onScreen: [1, 99, 10, 3], attached: false) == .shown(rehome: false, reorder: false))
        // Under its window it could not be seen.
        #expect(decide(onScreen: [1, 10, 99, 3], attached: false) == .shown(rehome: false, reorder: true))
        #expect(decide(onScreen: [99, 1, 10], attached: false) == .shown(rehome: false, reorder: true))
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
