import Foundation

/// What the tab takeover reads from a browser window before it presses
/// anything: where the tab strip and the toolbar are in the window, and the
/// two View menu items. All of it as read; nil is "not found" or "couldn't be
/// read", never a guess.
public struct TabStripReading: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var enabled: Bool?
        /// The item's checkmark. Brave never sets one, on or off.
        public var mark: String?
        public init(enabled: Bool?, mark: String?) { self.enabled = enabled; self.mark = mark }
    }
    /// The one group that holds the window's tabs, and the toolbar with the
    /// address field, in one coordinate space.
    public var tabs: CGRect?
    public var toolbar: CGRect?
    /// A tab's height: the unit the column's width is judged by.
    public var tabHeight: CGFloat?
    public var show: Item?
    public var collapse: Item?

    public init(tabs: CGRect?, toolbar: CGRect?, tabHeight: CGFloat?, show: Item?, collapse: Item?) {
        self.tabs = tabs; self.toolbar = toolbar; self.tabHeight = tabHeight; self.show = show; self.collapse = collapse
    }

    public enum Layout: Equatable, Sendable { case horizontal, vertical, unknown }
    public enum Column: Equatable, Sendable { case expanded, collapsed, unknown }
    public enum Press: Equatable, Sendable { case showVertically, collapse }

    /// Where the tabs are, from the window itself: a strip above the toolbar
    /// is across the top; one beside or below the toolbar is a column. Anything
    /// else is unknown.
    public var layout: Layout {
        guard let g = tabs, let t = toolbar, !g.isEmpty, !t.isEmpty else { return .unknown }
        let slack: CGFloat = 2 // Chrome's strip overlaps its toolbar by a point
        if g.maxY <= t.minY + slack { return .horizontal }
        if g.minY >= t.maxY - slack || g.maxX <= t.minX + slack || g.minX >= t.maxX - slack { return .vertical }
        return .unknown
    }

    /// How wide a column of tabs is, in tab heights: collapsed is about two
    /// (icons only), expanded several (icons and titles).
    public var column: Column {
        guard layout == .vertical, let g = tabs, let h = tabHeight, h > 0 else { return .unknown }
        let widths = g.width / h
        return widths <= 2.5 ? .collapsed : widths >= 4 ? .expanded : .unknown
    }

    private static func off(_ i: Item?) -> Bool { i?.enabled == true && (i?.mark ?? "").isEmpty }

    /// The one item to press now, or nil. Only when the window is seen to be
    /// in the other state, the item can be pressed, and its checkmark does not
    /// say otherwise.
    public var next: Press? {
        switch layout {
        case .horizontal: return Self.off(show) ? .showVertically : nil
        case .vertical: return column == .expanded && Self.off(collapse) ? .collapse : nil
        case .unknown: return nil
        }
    }

    public enum Result: Equatable, Sendable { case shown, notShown, unseen }

    /// What the window says a press of `press` came to: it shows what the
    /// press was for, it is seen still as it was, or it can't be told.
    public func result(of press: Press) -> Result {
        switch press {
        case .showVertically: return layout == .vertical ? .shown : layout == .horizontal ? .notShown : .unseen
        case .collapse: return column == .collapsed ? .shown : column == .expanded ? .notShown : .unseen
        }
    }

    public func shows(_ press: Press) -> Bool { result(of: press) == .shown }
}

/// One window's takeover, one look at a time: what to do after each reading.
/// At most two presses (vertical, then collapsed), each only when the window
/// is seen to be in the other state, each checked on the following looks.
public struct TabStripTakeoverFlow: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case press(TabStripReading.Press)
        /// The window is seen not to have changed: undo it, and leave this
        /// browser's tabs alone.
        case pressBack(TabStripReading.Press)
        case lookAgain
        case done
    }
    /// How many looks a press gets to show in the window, and a window not
    /// yet as wanted gets to become pressable, before that is how things are.
    public static let patience = 4
    private var pressed: TabStripReading.Press?
    private var presses = 0, looks = 0

    public init() {}

    public mutating func step(_ r: TabStripReading) -> Step {
        looks += 1
        if let p = pressed {
            switch r.result(of: p) {
            case .shown: break
            case .notShown:
                // Seen as it was, look after look: the press did nothing here.
                guard looks >= Self.patience else { return .lookAgain }
                pressed = nil
                return .pressBack(p)
            case .unseen:
                // What can't be seen is not pressed again, not even back.
                return looks >= Self.patience ? .done : .lookAgain
            }
        }
        guard let next = r.next, presses < 2 else {
            // Collapsed, or a browser without the item: this is how it stays.
            if r.column == .collapsed || r.show == nil { return .done }
            // Anything else may yet change: a window still opening shows no
            // tabs, the menu follows the focused window a moment late, and a
            // browser that can collapse offers it a moment after going vertical.
            return looks < Self.patience ? .lookAgain : .done
        }
        pressed = next; presses += 1; looks = 0
        return .press(next)
    }
}
