import Testing
@testable import Betterlink

/// Which app is in front is asked when an app comes forward, not on each
/// window title change (`BrowserWatcher` reads a title at once only while
/// its browser is in front): the tracker keeps the answer until the next.
@MainActor struct WindowTrackerFrontTests {
    @Test func theFrontAppIsTheOneLastBroughtForward() {
        let tracker = WindowTracker(browserBundleIds: [])
        #expect(tracker.frontPid == nil)
        tracker.frontAppChanged(to: 4242)
        #expect(tracker.frontPid == 4242)
        tracker.frontAppChanged(to: 77)
        #expect(tracker.frontPid == 77)
        tracker.frontAppChanged(to: nil)
        #expect(tracker.frontPid == nil)
    }
}
