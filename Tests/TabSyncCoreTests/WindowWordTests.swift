import Foundation
import Testing
@testable import TabSyncCore

/// The browser's own word for a window comes from the pairing: the type of
/// the browser window it is paired with. The pairing cases here pin what that
/// rests on once popups and app windows are among the browser windows handed
/// to it.
struct WindowWordTests {
    private static let big = WindowBounds(left: 0, top: 31, width: 748, height: 1259)
    private static let small = WindowBounds(left: 900, top: 31, width: 400, height: 600)

    private func entry(_ id: Int, _ type: String?, _ title: String, at b: WindowBounds, focused: Bool = false) -> SnapshotWindow {
        SnapshotWindow(id: id, focused: focused, windowType: type, tabs: [Tab(id: id * 10, windowId: id, title: title, active: true)],
                       left: b.left, top: b.top, width: b.width, height: b.height)
    }
    private func session(_ wins: [SnapshotWindow]) -> BrowserSession {
        var s = BrowserSession(socketPath: "/a")
        s.browserPid = 7
        var m = Inbound(type: "snapshot"); m.seq = 1; m.windows = wins
        s.store.apply(m)
        return s
    }
    private func ours(_ id: Int, _ title: String, at b: WindowBounds, focused: Bool = false) -> WindowPairing.Window {
        .init(id: id, pid: 7, app: "Dia", frame: b, title: title, focused: focused)
    }
    private func hit(_ w: Int) -> WindowPairing.Found { .window(.init(session: "/a", windowId: w)) }

    @Test func theWordIsTheTypeOfTheBrowserWindowAWindowIsPairedWith() {
        let s = session([entry(1, "normal", "Inbox", at: Self.big), entry(2, "popup", "Palette", at: Self.small),
                         entry(3, "app", "App", at: Self.small), entry(4, nil, "Old", at: Self.big)])
        #expect(WindowWord.word(for: hit(1), in: [s]) == .normal)
        #expect(WindowWord.word(for: hit(2), in: [s]) == .other)
        #expect(WindowWord.word(for: hit(3), in: [s]) == .other)
        // An extension older than 0.3.2 gives no type: normal, as before.
        #expect(WindowWord.word(for: hit(4), in: [s]) == .normal)
    }

    @Test func aWindowThatIsNotPairedHasNoWord() {
        let s = session([entry(1, "normal", "Inbox", at: Self.big)])
        for found in [WindowPairing.Found.unseen, .waiting, .notConnected] {
            #expect(WindowWord.word(for: found, in: [s]) == nil)
        }
        // Paired with a browser window that has closed since, or of a session that is gone.
        #expect(WindowWord.word(for: hit(9), in: [s]) == nil)
        #expect(WindowWord.word(for: hit(1), in: []) == nil)
    }

    // MARK: - What the pairing does with a popup among the browser's windows

    /// A popup exactly on a normal window, the popup not followed (Chrome,
    /// Brave: it shows no tabs): the window server counts two windows there.
    /// With the popup's own browser window reported there too, each window is
    /// accounted for and the normal window keeps its pairing. Left out, as it
    /// was before, the normal window showed nothing until it had the focus.
    @Test func aPopupExactlyOnANormalWindowLeavesItsPairingWhenThePopupIsReported() {
        let window = ours(100, "Inbox - Brave", at: Self.big), others = [7: [Self.big]]
        let both = session([entry(1, "normal", "Inbox", at: Self.big), entry(2, "popup", "Palette", at: Self.big)])
        var p = WindowPairing()
        let found = p.update([window], others: others, in: [both], now: 0)
        #expect(found[100] == hit(1))
        #expect(WindowWord.word(for: found[100] ?? .unseen, in: [both]) == .normal)
        let normalOnly = session([entry(1, "normal", "Inbox", at: Self.big)])
        var q = WindowPairing()
        #expect(q.update([window], others: others, in: [normalOnly], now: 0)[100] == .unseen)
    }

    /// A palette opening or closing is a window coming or going on the
    /// browser's side: what the extension reports differs, so the windows
    /// are counted again and a closed one is found.
    @Test func whatTheExtensionReportsCountsItsPopupsAndAppWindows() {
        let one = session([entry(1, "normal", "Inbox", at: Self.big)])
        let withPalette = session([entry(1, "normal", "Inbox", at: Self.big), entry(2, "popup", "Palette", at: Self.small)])
        let withApp = session([entry(1, "normal", "Inbox", at: Self.big), entry(3, "app", "App", at: Self.small)])
        #expect(WindowPairing.reported(in: [one]).count == 1)
        #expect(WindowPairing.reported(in: [withPalette]) == [.init(session: "/a", windowId: 1), .init(session: "/a", windowId: 2)])
        #expect(WindowPairing.reported(in: [withApp]) != WindowPairing.reported(in: [one]))
        // The palette's own window, awaiting its word, is one of the followed
        // windows the window server's list is checked for.
        let server = [WindowPairing.ServerWindow(number: 100, pid: 7, layer: 0, bounds: Self.big)]
        #expect(WindowPairing.closed([100, 101], in: server) == [101])
        #expect(WindowPairing.closed([100, 101], in: nil) == [])
    }

    /// Dia: a palette is followed, with no sidebar, until the browser's word
    /// for it comes. It pairs with its own browser window, a popup.
    @Test func aPaletteFollowedForItsWordPairsWithItsOwnPopup() {
        let s = session([entry(1, "normal", "Inbox", at: Self.big), entry(2, "popup", "Palette", at: Self.small, focused: true)])
        var p = WindowPairing()
        let found = p.update([ours(100, "Inbox", at: Self.big), ours(101, "Palette", at: Self.small, focused: true)], others: [:], in: [s], now: 0)
        #expect(found[100] == hit(1) && found[101] == hit(2))
        #expect(WindowWord.word(for: found[101] ?? .unseen, in: [s]) == .other)
        #expect(WindowWord.word(for: found[100] ?? .unseen, in: [s]) == .normal)
    }

    /// While a palette that isn't followed has the focus, the normal window
    /// must not pass for the focused one: the browser says its popup has the
    /// focus, and a title that can't be compared would let the focus pair the
    /// normal window with the popup. Told that no followed window has the
    /// focus, the pairing leaves it alone.
    @Test func aNormalWindowIsNotGivenTheFocusedPopupWhenItDoesNotHaveTheFocus() {
        let s = session([entry(1, "normal", "", at: Self.big), entry(2, "popup", "", at: Self.small, focused: true)])
        let others = [7: [Self.small]]
        var p = WindowPairing()
        for now in [0.0, 0.4, 0.8] {
            let found = p.update([ours(100, "", at: Self.big, focused: false)], others: others, in: [s], now: now)
            #expect(found[100] != hit(2), "at \(now)")
        }
        // The word it would wrongly get, were it passed off as focused.
        var q = WindowPairing()
        _ = q.update([ours(100, "", at: Self.big, focused: true)], others: others, in: [s], now: 0)
        #expect(q.update([ours(100, "", at: Self.big, focused: true)], others: others, in: [s], now: 0.4)[100] == hit(2))
    }
}
