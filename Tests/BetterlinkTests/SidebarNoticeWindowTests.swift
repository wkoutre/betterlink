import AppKit
import Testing
import TabSyncCore
@testable import Betterlink

/// The note's panel is the capsule's size, so the capsule sits where
/// `SidebarNotice.frame` puts the panel: 56 pt below the browser's top. Live at
/// 9eb0125 the panel was 368 x 1048 pt and the capsule drawn at its middle.
@MainActor @Suite struct SidebarNoticeWindowTests {
    @Test func thePanelIsTheCapsulesSize() {
        for notice in [SidebarNotice.noRoom, .noSize] {
            let size = SidebarNoticeWindow.size(of: SidebarNoticeWindow.host(notice.text))
            #expect(size.width <= 340 && size.width >= 200, "\(notice): \(size)")
            #expect(size.height <= 120 && size.height >= 30, "\(notice): \(size)")
        }
    }
}
