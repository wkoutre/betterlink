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
        #expect(MenuBarIcon.defaults(environment: ["BETTERLINK_HOME": "/dev/null/x"]) !== UserDefaults.standard)
        #expect(MenuBarIcon.defaults(environment: [:]) === UserDefaults.standard)
        #expect(MenuBarIcon.defaults(environment: ["BETTERLINK_HOME": ""]) === UserDefaults.standard)
    }

    private func tempFolder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("betterlink-tests-\(UUID().uuidString)")
    }
    private let fm = FileManager.default

    /// Two settings folders are two worlds: what one saves (Sync's folder and
    /// device, say) the other must never see.
    @Test func eachDevelopmentFolderHasItsOwnDomain() {
        let a = tempFolder(), b = tempFolder()
        defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        #expect(MenuBarIcon.developmentSuite(home: a.path) != MenuBarIcon.developmentSuite(home: b.path))
        #expect(MenuBarIcon.developmentSuite(home: a.path) == MenuBarIcon.developmentSuite(home: a.path))
    }

    /// A folder deleted and made again is a fresh one: old Sync settings there
    /// would sync the empty folder as a Mac that deleted everything.
    @Test func aFolderMadeAgainAtTheSamePathStartsOver() throws {
        let a = tempFolder()
        defer { try? fm.removeItem(at: a) }
        let first = MenuBarIcon.developmentSuite(home: a.path)
        try fm.removeItem(at: a)
        #expect(MenuBarIcon.developmentSuite(home: a.path) != first)
    }

    @Test func aCopiedFolderIsAnotherFolder() throws {
        let a = tempFolder(), b = tempFolder()
        defer { try? fm.removeItem(at: a); try? fm.removeItem(at: b) }
        let first = MenuBarIcon.developmentSuite(home: a.path)
        try fm.copyItem(at: a, to: b)
        #expect(MenuBarIcon.developmentSuite(home: b.path) != first)
        #expect(MenuBarIcon.developmentSuite(home: a.path) == first)
    }

    /// However it is written, and whether or not it exists yet.
    @Test func oneFolderHasOneDomain() throws {
        let parent = tempFolder(), link = tempFolder()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: parent)
        defer { try? fm.removeItem(at: link); try? fm.removeItem(at: parent) }
        let name = MenuBarIcon.developmentSuite(home: link.path + "/new") // not made yet, under a link
        for other in ["/new", "/new/", "/./new"] {
            #expect(MenuBarIcon.developmentSuite(home: parent.path + other) == name)
            #expect(MenuBarIcon.developmentSuite(home: link.path + other) == name)
        }
    }

    /// Nowhere to keep an id: a domain nobody else has, never a shared one.
    @Test func aFolderThatCantBeWrittenSharesNothing() {
        #expect(MenuBarIcon.developmentSuite(home: "/dev/null/x") != MenuBarIcon.developmentSuite(home: "/dev/null/x"))
    }
}
