import CoreGraphics
import Testing
@testable import TabSyncCore

/// When the sidebar can't open, the note says why, in plain words, over its window.
@Suite struct SidebarNoticeTests {
    private let frame = CGRect(x: 1256, y: 0, width: 800, height: 1259)

    @Test func roomEnoughNeedsNoNote() {
        #expect(SidebarNotice.refusal(frame: frame, took: 600) == nil)
        #expect(SidebarNotice.refusal(frame: frame, took: 520) == nil)
    }

    /// Brave at 615 of 800: 185 left, under the sidebar's least 200.
    @Test func aBrowserThatStopsShortHasNoRoom() {
        #expect(SidebarNotice.refusal(frame: frame, took: 615) == .noRoom)
        #expect(SidebarNotice.noRoom.text == "There isn't room for the sidebar beside this window. Make the window wider.")
    }

    @Test func aBrowserThatTakesNoSize() {
        #expect(SidebarNotice.refusal(frame: frame, took: 800) == .noSize)
        #expect(SidebarNotice.noSize.text == "This window didn't make room for the sidebar. Resize it a little and try again.")
    }

    /// Centered on the window, below its top, and inside the display's visible frame.
    @Test func theNoteSitsOverTheWindowOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        let f = SidebarNotice.frame(size: CGSize(width: 340, height: 60), window: frame, visible: visible)
        #expect(f.midX == frame.midX && f.maxY == frame.maxY - 56)
        // A window half off the right edge: the note stays on screen.
        let off = SidebarNotice.frame(size: CGSize(width: 340, height: 60), window: CGRect(x: 1900, y: 0, width: 800, height: 1259), visible: visible)
        #expect(off.maxX <= visible.maxX - 8)
    }
}
