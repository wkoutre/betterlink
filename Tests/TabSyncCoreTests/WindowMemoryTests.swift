import Foundation
import Testing
@testable import TabSyncCore

struct WindowMemoryTests {
    @Test func everyWindowHiddenOneByOneReadsAsHiddenWhateverTheSetting() {
        #expect(WindowMemory.allHidden([true, true], setting: false))
        #expect(!WindowMemory.allHidden([true, false], setting: true))
        #expect(!WindowMemory.allHidden([false, false], setting: true))
        #expect(WindowMemory.allHidden([], setting: true))
        #expect(!WindowMemory.allHidden([], setting: false))
    }

    @Test func eachWindowHasItsOwn() {
        var m = WindowMemory()
        m.set(hidden: true, window: 1, pid: 7)
        m.set(width: 320, window: 2, pid: 7)
        #expect(m.hidden(window: 1, pid: 7) == true)
        #expect(m.width(window: 1, pid: 7) == nil)
        #expect(m.hidden(window: 2, pid: 7) == nil)
        #expect(m.width(window: 2, pid: 7) == 320)
        m.set(width: 250, window: 1, pid: 7)
        #expect(m.hidden(window: 1, pid: 7) == true && m.width(window: 1, pid: 7) == 250)
    }

    @Test func survivesARelaunch() throws {
        var m = WindowMemory()
        m.set(hidden: true, window: 1, pid: 7)
        #expect(try JSONDecoder().decode(WindowMemory.self, from: JSONEncoder().encode(m)) == m)
    }

    @Test func aNumberInAnotherProcessIsAnotherWindow() {
        var m = WindowMemory()
        m.set(hidden: true, window: 1, pid: 7)
        #expect(m.hidden(window: 1, pid: 8) == nil)
        m.set(width: 300, window: 1, pid: 8)
        #expect(m.hidden(window: 1, pid: 7) == nil)
    }

    @Test func closedWindowsAreDroppedAndItNeverGrowsPastFifty() {
        var m = WindowMemory()
        for n in 1...60 { m.set(hidden: true, window: UInt32(n), pid: 7) }
        #expect(m.entries.count == 50 && m.hidden(window: 60, pid: 7) == true)
        m.prune(alive: [60])
        #expect(m.entries.map(\.window) == [60])
        m.forget(window: 60)
        #expect(m.entries.isEmpty)
    }

    @Test func settingItForEveryWindowLeavesTheOther() {
        var m = WindowMemory()
        m.set(hidden: true, window: 1, pid: 7)
        m.set(width: 300, window: 1, pid: 7)
        m.set(hidden: false, window: 2, pid: 7)
        m.forgetHidden()
        #expect(m.entries.map(\.window) == [1])
        #expect(m.width(window: 1, pid: 7) == 300)
        m.forgetWidths()
        #expect(m.entries.isEmpty)
    }
}
