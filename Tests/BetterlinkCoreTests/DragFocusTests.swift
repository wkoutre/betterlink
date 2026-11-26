import Testing
@testable import BetterlinkCore

@Suite struct DragFocusTests {
    /// What the sidebar saw, in order. The answers: true where the field is
    /// to be given the keyboard.
    private enum Seen { case began(focused: Bool), ended(hasKeyboard: Bool), fieldAppeared, settled }

    private func given(_ seen: Seen...) -> [Bool] {
        var f = DragFocus()
        return seen.compactMap {
            switch $0 {
            case .began(let focused): f.began(focused: focused); return nil
            case .ended(let has): return f.ended(hasKeyboard: has)
            case .fieldAppeared: return f.fieldAppeared()
            case .settled: f.settle(); return nil
            }
        }
    }

    /// The drag is seen to end while the field is still swapped out, where a
    /// focus set does not take: the keyboard stays owed until the field is back.
    @Test func owedUntilTheFieldIsBackInView() {
        #expect(given(.began(focused: true), .ended(hasKeyboard: false), .fieldAppeared) == [true, true])
        // The other order: back in view while the drag is not yet seen to end.
        #expect(given(.began(focused: true), .fieldAppeared, .ended(hasKeyboard: false)) == [false, true])
    }

    /// Owed only once the drag is over.
    @Test func nothingIsGivenWhileTheDragIsOn() {
        var f = DragFocus()
        f.began(focused: true)
        #expect(!f.owes)
        _ = f.ended(hasKeyboard: false)
        #expect(f.owes)
    }

    /// A drag that never swapped the field out left it the keyboard.
    @Test func aFieldThatKeptTheKeyboardIsOwedNothing() {
        #expect(given(.began(focused: true), .ended(hasKeyboard: true), .fieldAppeared) == [false, false])
    }

    @Test func aFieldWithoutTheKeyboardIsLeftWithout() {
        #expect(given(.began(focused: false), .fieldAppeared, .ended(hasKeyboard: false), .fieldAppeared) == [false, false, false])
    }

    /// Once the field has the keyboard, or the last try was made, nothing is
    /// owed: the field appearing later for another reason (another Sidebar
    /// Profile, say) takes no keyboard.
    @Test func nothingIsOwedOnceSettled() {
        #expect(given(.began(focused: true), .ended(hasKeyboard: false), .settled, .fieldAppeared) == [true, false])
        #expect(given(.began(focused: true), .ended(hasKeyboard: false), .settled, .began(focused: false), .ended(hasKeyboard: false)) == [true, false])
    }

    /// A drag's end is seen a moment after the mouse comes up. One begun
    /// meanwhile, or before the field has the keyboard back, finds it without:
    /// what the first drag saw stands.
    @Test func aDragBegunBeforeTheLastWasSettledKeepsWhatItSaw() {
        #expect(given(.began(focused: true), .began(focused: false), .ended(hasKeyboard: false)) == [true])
        #expect(given(.began(focused: true), .ended(hasKeyboard: false), .began(focused: false), .ended(hasKeyboard: false)) == [true, true])
    }
}
