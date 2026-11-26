import AppKit
import BetterlinkCore
import Testing
import UniformTypeIdentifiers
@testable import Betterlink

@MainActor @Suite struct SidebarDragProviderTests {
    private let saved = SidebarView.savedKey(UUID())
    private let tab = "betterlink-tab:3:17"

    private func dropped(_ providers: [NSItemProvider]) async -> [String] {
        await withCheckedContinuation { done in
            SidebarDrag.keys(from: providers) { done.resume(returning: $0) }
        }
    }

    /// Dropped on a web page, a row hands over nothing the page can read. As
    /// text, the browser opened "betterlink-saved:…" as an address.
    @Test func aDraggedRowOffersNoTextAndNoAddress() {
        for key in [saved, tab] {
            let p = SidebarDrag.provider(for: key)
            #expect(p.registeredTypeIdentifiers == [SidebarDrag.typeIdentifier])
            for other in [UTType.text, .plainText, .utf8PlainText, .url, .fileURL] {
                #expect(!p.hasItemConformingToTypeIdentifier(other.identifier), "offers \(other.identifier)")
            }
            #expect(!p.canLoadObject(ofClass: NSString.self))
            #expect(!p.canLoadObject(ofClass: NSURL.self))
        }
    }

    /// The sidebar's own drop targets read the keys back, several in order.
    @Test func theSidebarReadsItsOwnDragsBackInOrder() async {
        let keys = [saved, tab, SidebarView.savedKey(UUID())]
        #expect(await dropped(keys.map { SidebarDrag.provider(for: $0) }) == keys)
    }

    /// Text dragged in from another app is no row of the sidebar's, whatever it says.
    @Test func textFromElsewhereIsNotAKey() async {
        #expect(await dropped([NSItemProvider(object: saved as NSString)]) == [])
    }
}
