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

    @Test func shiftAloneNoKeyOrTheBrowsersCommandShortcutsAreRefused() {
        #expect(!Shortcut(keyCode: 0, modifiers: Shortcut.shift, key: "A").isValid)
        #expect(!Shortcut(keyCode: 0, modifiers: 0, key: "A").isValid)
        #expect(!Shortcut(keyCode: 0, modifiers: Shortcut.control, key: "").isValid)
        // ⌘T and ⇧⌘T are the browser's own (review F4).
        #expect(!Shortcut(keyCode: 17, modifiers: Shortcut.command, key: "T").isValid)
        #expect(!Shortcut(keyCode: 17, modifiers: Shortcut.command | Shortcut.shift, key: "T").isValid)
        // ⌥⌘I is the browser's DevTools and ⌥S types ß (review round 2).
        #expect(!Shortcut(keyCode: 34, modifiers: Shortcut.command | Shortcut.option, key: "I").isValid)
        #expect(!Shortcut(keyCode: 1, modifiers: Shortcut.option, key: "S").isValid)
        #expect(Shortcut(keyCode: 1, modifiers: Shortcut.control | Shortcut.shift, key: "S").isValid)
    }

    @Test func specialKeysGetReadableLabels() {
        #expect(Shortcut.label(keyCode: 49, typed: " ") == "Space")
        #expect(Shortcut.label(keyCode: 122, typed: "\u{F704}") == "F1")
        #expect(Shortcut.label(keyCode: 126, typed: "\u{F700}") == "↑")
        #expect(Shortcut.label(keyCode: 1, typed: "s") == "S")
        #expect(Shortcut.label(keyCode: 200, typed: "\u{F750}") == "")
    }

    @Test func itRoundTripsThroughDefaultsAndIgnoresJunk() throws {
        let d = try #require(UserDefaults(suiteName: "bl-shortcut-\(UUID().uuidString)"))
        let s = Shortcut(keyCode: 11, modifiers: Shortcut.control | Shortcut.option, key: "B")
        s.save(d, key: "k")
        #expect(Shortcut.load(d, key: "k") == s)
        d.set(Data("nope".utf8), forKey: "k")
        #expect(Shortcut.load(d, key: "k") == nil)
    }
}
