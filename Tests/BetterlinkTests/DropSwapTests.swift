import AppKit
import SwiftUI
import Testing
@testable import Betterlink

@MainActor @Suite struct DropSwapTests {
    private func height(showing: Bool, line: CGFloat) -> CGFloat {
        let view = VStack(spacing: 0) {
            DropSwap(showing: showing, height: 24) {
                Text("Drag here").frame(minHeight: 30)
            } line: {
                Color.clear.frame(height: line)
            }
            Color.clear.frame(height: 100) // the rows below
        }
        return NSHostingView(rootView: view.frame(width: 260)).fittingSize.height
    }

    /// Starting a drag must not move the rows: what the pointer is over stays
    /// where it was.
    @Test func showingTheZoneMovesNothingBelow() {
        for line in [CGFloat(10), 24, 40] {
            #expect(height(showing: true, line: line) == height(showing: false, line: line))
        }
        #expect(height(showing: true, line: 24) == 124)
    }
}
