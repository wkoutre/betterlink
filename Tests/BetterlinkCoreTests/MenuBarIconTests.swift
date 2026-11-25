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

    /// Two settings folders are two worlds: what one saves (Sync's folder and
    /// device, say) the other must never see.
    @Test func eachDevelopmentFolderHasItsOwnPreferences() {
        func defaults(_ home: String) -> UserDefaults { MenuBarIcon.defaults(environment: ["BETTERLINK_HOME": home]) }
        let a = "/tmp/betterlink-tests-\(UUID().uuidString)", b = a + "-other"
        defer { for h in [a, b] { defaults(h).removePersistentDomain(forName: MenuBarIcon.developmentSuite(home: h)) } }
        defaults(a).set("/Drive", forKey: "sync.folder")
        #expect(defaults(a).string(forKey: "sync.folder") == "/Drive")
        #expect(defaults(b).string(forKey: "sync.folder") == nil)
        #expect(UserDefaults.standard.string(forKey: "sync.folder") != "/Drive")
    }

    /// The app and the CLI may spell the same folder differently.
    @Test func oneFolderHasOneDomainHoweverItIsWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: dir) }
        let name = MenuBarIcon.developmentSuite(home: dir.path)
        for other in [dir.path + "/", dir.path + "/./", link.path] { #expect(MenuBarIcon.developmentSuite(home: other) == name) }
        #expect(MenuBarIcon.developmentSuite(home: "~/x") == MenuBarIcon.developmentSuite(home: NSHomeDirectory() + "/x"))
    }
}
