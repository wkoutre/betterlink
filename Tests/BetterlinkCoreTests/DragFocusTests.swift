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

    /// AppKit selects all of a field's text as it takes the keyboard, so the
    /// next key typed would replace it: the caret goes back where it was.
    @Test func theCaretGoesBackWhereItWas() {
        var f = DragFocus()
        f.began(focused: true, caret: 2)
        #expect(f.caret(selected: 0..<3, length: 3) == 2)
        f = DragFocus()
        f.began(focused: true, caret: 3)
        // A drag begun before the last was settled finds no field: the first's caret stands.
        f.began(focused: false, caret: nil)
        #expect(f.caret(selected: 0..<3, length: 3) == 3)
    }

    /// Not known, or past what is there now: at the end, so typing goes on.
    @Test func aCaretNotKnownGoesToTheEnd() {
        var f = DragFocus()
        f.began(focused: true)
        #expect(f.caret(selected: 0..<3, length: 3) == 3)
        f.began(focused: true, caret: 9)
        #expect(f.caret(selected: 0..<3, length: 3) == 3)
        #expect(f.caret(selected: 0..<0, length: 0) == 0)
    }

    /// Only AppKit's select-all is undone. A caret or selection that is not
    /// the whole text is the person's own (a click into the field): left alone.
    @Test func aSelectionThatIsNotTheWholeTextIsLeftAlone() {
        var f = DragFocus()
        f.began(focused: true, caret: 3)
        #expect(f.caret(selected: 1..<1, length: 3) == nil)
        #expect(f.caret(selected: 0..<2, length: 3) == nil)
    }

    /// A drag's end is seen a moment after the mouse comes up. One begun
    /// meanwhile, or before the field has the keyboard back, finds it without:
    /// what the first drag saw stands.
    @Test func aDragBegunBeforeTheLastWasSettledKeepsWhatItSaw() {
        #expect(given(.began(focused: true), .began(focused: false), .ended(hasKeyboard: false)) == [true])
        #expect(given(.began(focused: true), .ended(hasKeyboard: false), .began(focused: false), .ended(hasKeyboard: false)) == [true, true])
    }
}
