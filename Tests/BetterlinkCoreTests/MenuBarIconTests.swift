import Foundation
import Testing
@testable import BetterlinkCore

struct MenuBarIconTests {
    private func fresh() -> UserDefaults {
        let name = "betterlink.tests.menubar.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func shownUntilTurnedOff() {
        let d = fresh()
        #expect(MenuBarIcon.isShown(in: d))
        MenuBarIcon.setShown(false, in: d)
        #expect(!MenuBarIcon.isShown(in: d))
        MenuBarIcon.setShown(true, in: d)
        #expect(MenuBarIcon.isShown(in: d))
    }

    @Test func developmentNeverUsesTheRealSetting() {
        #expect(MenuBarIcon.defaults(environment: ["BETTERLINK_HOME": "/tmp/x"]) !== UserDefaults.standard)
        #expect(MenuBarIcon.defaults(environment: [:]) === UserDefaults.standard)
        #expect(MenuBarIcon.defaults(environment: ["BETTERLINK_HOME": ""]) === UserDefaults.standard)
    }
}
