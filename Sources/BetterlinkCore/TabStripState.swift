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

    /// Whether the window now shows what `press` was for.
    public func shows(_ press: Press) -> Bool {
        switch press {
        case .showVertically: return layout == .vertical
        case .collapse: return column == .collapsed
        }
    }
}

/// One window's takeover, one look at a time: what to do after each reading.
/// At most two presses (vertical, then collapsed), each only when the window
/// is seen to be in the other state, each checked on the following looks.
public struct TabStripTakeoverFlow: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case press(TabStripReading.Press)
        /// It did not show: undo it, and leave this browser's tabs alone.
        case pressBack(TabStripReading.Press)
        case lookAgain
        case done
    }
    private var pressed: TabStripReading.Press?
    private var presses = 0, looks = 0

    public init() {}

    public mutating func step(_ r: TabStripReading) -> Step {
        looks += 1
        if let p = pressed, !r.shows(p) {
            // A browser still laying out gets a second look, no more.
            guard looks >= 2 else { return .lookAgain }
            pressed = nil
            return .pressBack(p)
        }
        guard let next = r.next, presses < 2 else {
            // Just gone vertical: a browser that can collapse offers it a
            // moment later. Two more looks, then this is how it stays.
            if pressed == .showVertically, r.column != .collapsed, looks <= 2 { return .lookAgain }
            return .done
        }
        pressed = next; presses += 1; looks = 0
        return .press(next)
    }
}
