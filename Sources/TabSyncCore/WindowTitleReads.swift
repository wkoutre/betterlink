import Foundation

/// When a followed browser window's title is read over Accessibility
/// (`TrackedWindow`). A window's title follows its tab's, which can change
/// twice a second all day. Behind another app nothing shows it and the tab
/// lists come every 2 s (`PublishPacer`): a change is only marked, and read at
/// the next pairing, which those lists bring, at most once however often the
/// browser renamed the window meanwhile. In front it is read at once, as the
/// pairing then keeps to the moment.
public struct WindowTitleReads: Equatable, Sendable {
    /// The title changed behind another app and hasn't been read since.
    public private(set) var changed = false

    public init() {}

    /// The browser says the title changed: true when it is to be read now.
    public mutating func titleChanged(browserInFront: Bool) -> Bool {
        changed = !browserInFront
        return browserInFront
    }

    /// A pairing is about to use the title: true when it is to be read now,
    /// once per change. `readable`: the browser answers (a stalled one isn't
    /// asked, and the change waits for the next pairing).
    public mutating func pairing(readable: Bool) -> Bool {
        guard changed, readable else { return false }
        changed = false
        return true
    }

    /// The window was read whole, its title with it.
    public mutating func readWhole() { changed = false }
}
