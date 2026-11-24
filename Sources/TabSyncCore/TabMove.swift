/// Reordering a window's tabs by dragging one next to another.
public enum TabMove {
    /// The index to hand the browser's tab move so the tab now at `from` ends
    /// up just before (or, with `after`, just after) the tab now at `target`.
    /// The browser counts the index in the window as it is after the tab
    /// leaves, so moving right lands one lower. Nil when it is there already.
    public static func index(moving from: Int, nextTo target: Int, after: Bool) -> Int? {
        var to = after ? target + 1 : target
        if from < to { to -= 1 }
        return to == from ? nil : to
    }
}
