import Testing
@testable import Betterlink

/// The Sidebar page's order, and what it shows while the sidebar is off.
/// SidebarPage draws its sections and the Sidebar section's rows from this
/// plan, in this order.
@Suite struct SidebarPagePlanTests {
    private let flags = [true, false]

    @Test func theSidebarSectionAndItsSwitchComeFirst() {
        for enabled in flags {
            let plan = SidebarPagePlan(enabled: enabled)
            #expect(plan.sections.first == .sidebar)
            #expect(plan.rows.first == .show)
        }
        #expect(SidebarPagePlan(enabled: true).sections == [.sidebar, .browsers, .options, .imports])
    }

    /// Off, the switch is all there is, whatever else is true of this Mac.
    @Test func offShowsOnlyTheSwitch() {
        for apart in flags {
            for corners in flags {
                for trusted in flags {
                    let plan = SidebarPagePlan(enabled: false, canTellWindowsApart: apart, readsWindowCorners: corners, trusted: trusted)
                    #expect(plan.sections == [.sidebar])
                    #expect(plan.rows == [.show])
                }
            }
        }
    }

    @Test func onShowsItsSettingsUnderTheSwitch() {
        #expect(SidebarPagePlan(enabled: true).rows == [.show, .side, .shortcut])
    }

    /// What is wrong on this Mac sits between the switch and the settings,
    /// and only what is wrong.
    @Test func onSaysWhatThisMacIsMissing() {
        #expect(SidebarPagePlan(enabled: true, trusted: false).rows == [.show, .accessibility, .side, .shortcut])
        #expect(SidebarPagePlan(enabled: true, canTellWindowsApart: false).rows == [.show, .windowsWarning, .side, .shortcut])
        #expect(SidebarPagePlan(enabled: true, readsWindowCorners: false).rows == [.show, .cornersNote, .side, .shortcut])
        #expect(SidebarPagePlan(enabled: true, canTellWindowsApart: false, readsWindowCorners: false, trusted: false).rows
            == [.show, .windowsWarning, .cornersNote, .accessibility, .side, .shortcut])
    }

    /// The page animates when its plan changes, so the plan changes exactly
    /// when the page does.
    @Test func thePlanChangesWithTheSwitch() {
        #expect(SidebarPagePlan(enabled: true) != SidebarPagePlan(enabled: false))
        #expect(SidebarPagePlan(enabled: true) == SidebarPagePlan(enabled: true))
    }
}
