import AppKit
import SwiftUI
import Testing
@testable import Betterlink

@MainActor @Suite struct RuleNumberTests {
    private func size(_ number: Int, of count: Int) -> CGSize {
        NSHostingView(rootView: RuleNumber(number: number, count: count)).fittingSize
    }

    /// Rule 10 used to wrap to "1" over "0" in a column sized for one digit.
    @Test func twoAndThreeDigitNumbersStayOnOneLine() {
        let line = size(1, of: 1).height
        for (n, count) in [(10, 10), (12, 15), (100, 100), (123, 150)] {
            #expect(size(n, of: count).height == line, "\(n) wrapped")
        }
    }

    /// Every row in one list gets the same column, so the sentences line up.
    @Test func everyRowInAListHasTheSameWidth() {
        for count in [9, 10, 100] {
            let widths = Set([1, 9, count].map { size($0, of: count).width })
            #expect(widths.count == 1, "count \(count): \(widths)")
        }
        #expect(size(1, of: 100).width > size(1, of: 10).width)
        #expect(size(1, of: 10).width > size(1, of: 9).width)
    }
}
