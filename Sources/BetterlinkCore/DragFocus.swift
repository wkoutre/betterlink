/// Whether the sidebar's New Tab field takes the keyboard back when a drag
/// ends. While a row is dragged the field is swapped for a drop zone
/// (DropSwap) and loses the keyboard; before this it stayed lost.
///
/// What is owed is kept until the field is seen to have the keyboard, or the
/// last try was made (`settle`): a focus set while the field is still swapped
/// out does not take, and the drag is often seen to end before the field is back.
public struct DragFocus: Equatable, Sendable {
    private var dragging = false
    /// The field had the keyboard when a drag began, and hasn't had it back.
    private var owed = false

    public init() {}

    /// The drag is over and the field is still to get the keyboard back.
    public var owes: Bool { owed && !dragging }

    /// A drag began. `focused`: the field has the keyboard now. One begun
    /// before the last was settled finds the field without: what was owed stands.
    public mutating func began(focused: Bool) {
        owed = owed || focused
        dragging = true
    }

    /// The drag ended, dropped or not. `hasKeyboard`: the field has it now (it
    /// was never swapped out). True: the field is owed the keyboard.
    public mutating func ended(hasKeyboard: Bool) -> Bool {
        dragging = false
        if hasKeyboard { owed = false }
        return owed
    }

    /// The field is back in view. True: give it the keyboard now.
    public func fieldAppeared() -> Bool { owes }

    /// The field has the keyboard, or the last try was made: nothing more is
    /// owed, so the field appearing later for another reason takes none.
    public mutating func settle() {
        if !dragging { owed = false }
    }
}
