/// Whether the sidebar's New Tab field takes the keyboard back when a drag
/// ends. While a row is dragged the field is swapped for a drop zone
/// (DropSwap) and loses the keyboard; before this it stayed lost.
public struct DragFocus: Equatable, Sendable {
    private var dragging = false
    /// The field had the keyboard when the drag began, and hasn't had it back.
    private var owed = false

    public init() {}

    /// A drag began. `focused`: the field has the keyboard now.
    public mutating func began(focused: Bool) {
        // Begun before the last drag was seen to end, the field is already
        // swapped out: what that drag saw stands.
        owed = focused || (dragging && owed)
        dragging = true
    }

    /// The drag ended, dropped or not. True: give the field the keyboard.
    public mutating func ended() -> Bool {
        defer { self = DragFocus() }
        return owed
    }

    /// The field is back in view. True: give it the keyboard.
    public mutating func fieldAppeared() -> Bool {
        defer { owed = false }
        return owed
    }
}
