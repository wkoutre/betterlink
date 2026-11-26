import AppKit
import SwiftUI
import Testing
import TabSyncCore
@testable import Betterlink

/// The note's panel is the capsule's size, so the capsule sits where
/// `SidebarNotice.frame` puts the panel: 56 pt below the browser's top. Live at
/// 9eb0125 the panel was 368 x 1048 pt and the capsule drawn at its middle.
@MainActor @Suite struct SidebarNoticeWindowTests {
    /// Laid out over Brave at the mini's right edge (1256, 31 from the top,
    /// 800 x 1259): the panel stays the capsule's size, 56 pt below the
    /// window's top, the capsule filling it.
    @Test func thePanelStaysWhereItIsPut() {
        let window = CGRect(x: 1256, y: 0, width: 800, height: 1259)
        let visible = CGRect(x: 0, y: 0, width: 2056, height: 1259)
        for notice in [SidebarNotice.noRoom, .noSize] {
            let (panel, want) = SidebarNoticeWindow.shared.prepare(notice.text, over: window, visible: visible)
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.layoutIfNeeded()
            #expect(panel.frame == want, "\(notice): panel at \(panel.frame), put at \(want)")
            #expect(want.height <= 120 && want.maxY == window.maxY - 56, "\(notice): \(want)")
            #expect(panel.contentView?.frame.size == want.size, "\(notice): content \(panel.contentView?.frame ?? .zero)")
            // SwiftUI never sizes the panel: on screen its size constraints (worked out once at a width of
            // nothing, a word to a line) grew it to 368 x 1048 pt live, which no headless layout shows.
            if let host = panel.contentView as? NSHostingView<SidebarNoticeView> {
                #expect(host.sizingOptions.isEmpty, "\(notice): the hosting view sizes the panel (\(host.sizingOptions))")
            } else {
                Issue.record("\(notice): the panel's content is \(type(of: panel.contentView))")
            }
        }
    }

    @Test func thePanelIsTheCapsulesSize() {
        for notice in [SidebarNotice.noRoom, .noSize] {
            let size = SidebarNoticeWindow.size(of: notice.text)
            // At most 320 pt of text, 16 pt either side of it, and the 8 pt clear margin.
            #expect(size.width <= 368 && size.width >= 200, "\(notice): \(size)")
            #expect(size.height <= 120 && size.height >= 30, "\(notice): \(size)")
        }
    }
}
