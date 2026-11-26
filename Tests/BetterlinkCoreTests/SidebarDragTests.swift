import Foundation
import Testing
@testable import BetterlinkCore

@Suite struct SidebarDragTests {
    @Test func aKeyComesBackFromItsData() {
        for key in ["betterlink-saved:\(UUID().uuidString)", "betterlink-tab:3:17"] {
            #expect(SidebarDrag.key(from: SidebarDrag.data(for: key)) == key)
        }
        #expect(SidebarDrag.key(from: Data()) == nil)
        #expect(SidebarDrag.key(from: Data([0xFF, 0xFE])) == nil)
    }

    /// The shipped Info.plist declares the drag's type, and as data only: a
    /// type that was also text or a URL is one other apps would take.
    @Test func infoPlistExportsTheTypeAsDataOnly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let exported = info["UTExportedTypeDeclarations"] as? [[String: Any]] ?? []
        let mine = try #require(exported.first { $0["UTTypeIdentifier"] as? String == SidebarDrag.typeIdentifier })
        #expect(mine["UTTypeConformsTo"] as? [String] == ["public.data"])
        // No file extension or MIME type: nothing on disk or the web is one.
        #expect(mine["UTTypeTagSpecification"] == nil)
    }
}
