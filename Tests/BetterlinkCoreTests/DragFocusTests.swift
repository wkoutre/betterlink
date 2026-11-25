import Testing
@testable import BetterlinkCore

@Suite struct DragFocusTests {
    /// What a drag saw, in order: true where the field is given the keyboard.
    private enum Seen { case began(focused: Bool), ended, fieldAppeared }

    private func given(_ seen: Seen...) -> [Bool] {
        var f = DragFocus()
        return seen.compactMap {
            switch $0 {
            case .began(let focused): f.began(focused: focused); return nil
            case .ended: return f.ended()
            case .fieldAppeared: return f.fieldAppeared()
            }
        }
    }

    /// Dropped or cancelled, the field that had the keyboard has it again.
    @Test func theFieldGetsTheKeyboardBackWhenTheDragEnds() {
        #expect(given(.began(focused: true), .ended) == [true])
    }

    @Test func aFieldWithoutTheKeyboardIsLeftWithout() {
        #expect(given(.began(focused: false), .fieldAppeared, .ended) == [false, false])
    }

    /// The field coming back and the drag ending are seen in either order:
    /// the keyboard is given once.
    @Test func givenOnceWhicheverIsSeenFirst() {
        #expect(given(.began(focused: true), .fieldAppeared, .ended) == [true, false])
        #expect(given(.began(focused: true), .ended, .fieldAppeared) == [true, false])
    }

    /// Once the drag is over nothing is owed: the field appearing later for
    /// another reason (another Sidebar Profile, say) takes no keyboard.
    @Test func nothingIsOwedAfterTheDrag() {
        #expect(given(.began(focused: true), .ended, .fieldAppeared, .began(focused: false), .ended) == [true, false, false])
    }

    /// A drag's end is seen a moment after the mouse comes up. One begun in
    /// that moment finds the field already swapped out: what the first saw stands.
    @Test func aDragBegunBeforeTheLastWasSeenToEndKeepsWhatItSaw() {
        #expect(given(.began(focused: true), .began(focused: false), .ended) == [true])
    }
}
