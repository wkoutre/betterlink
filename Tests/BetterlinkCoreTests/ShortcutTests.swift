import Foundation
import Testing
@testable import BetterlinkCore

struct ShortcutTests {
    @Test func theDefaultIsControlOptionS() {
        #expect(Shortcut.sidebarDefault.display == "⌃⌥S")
        #expect(Shortcut.sidebarDefault.isValid)
    }

    @Test func displayFollowsTheMenuOrder() {
        let s = Shortcut(keyCode: 0, modifiers: Shortcut.command | Shortcut.shift | Shortcut.control | Shortcut.option, key: "A")
        #expect(s.display == "⌃⌥⇧⌘A")
    }

    @Test func shiftAloneOrNoKeyIsRefused() {
        #expect(!Shortcut(keyCode: 0, modifiers: Shortcut.shift, key: "A").isValid)
        #expect(!Shortcut(keyCode: 0, modifiers: 0, key: "A").isValid)
        #expect(!Shortcut(keyCode: 0, modifiers: Shortcut.command, key: "").isValid)
    }

    @Test func itRoundTripsThroughDefaultsAndIgnoresJunk() throws {
        let d = try #require(UserDefaults(suiteName: "bl-shortcut-\(UUID().uuidString)"))
        let s = Shortcut(keyCode: 11, modifiers: Shortcut.command | Shortcut.option, key: "B")
        s.save(d, key: "k")
        #expect(Shortcut.load(d, key: "k") == s)
        d.set(Data("nope".utf8), forKey: "k")
        #expect(Shortcut.load(d, key: "k") == nil)
    }
}
