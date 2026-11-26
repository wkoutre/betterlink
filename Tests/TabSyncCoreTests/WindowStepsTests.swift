import CoreGraphics
import Testing
@testable import TabSyncCore

/// One call at a time, each waited for on screen. Each test plays the browser.
@Suite struct WindowStepsTests {
    private let full = CGRect(x: 0, y: 0, width: 2056, height: 1290)
    private let narrowed = CGRect(x: 280, y: 0, width: 1776, height: 1290)

    /// Runs the steps against a window that takes each call at once (or not:
    /// `takesSize`), and returns the calls and where it ends.
    private func run(_ steps: WindowSteps, from start: CGRect, takesSize: Bool = true, least: CGFloat = 0) -> ([WindowSteps.Call], CGRect) {
        var s = steps, w = start, calls: [WindowSteps.Call] = [], t = 0.0
        while !s.done, t < 10 {
            if let c = s.step(seen: w, now: t) {
                calls.append(c)
                switch c {
                case .size(let f): if takesSize { w.size.width = max(least, f.width); w.origin.y = w.maxY - f.height; w.size.height = f.height }
                case .position(let f): w.origin.x = f.minX; w.origin.y = f.maxY - w.height
                }
            }
            t += 1.0 / 120
        }
        return (calls, w)
    }

    @Test func narrowingSizesFirstThenMovesKeepingTheFarEdge() {
        let (calls, end) = run(WindowSteps(target: narrowed, keep: .left), from: full)
        #expect(end == narrowed)
        guard case .size = calls.first, case .position = calls.dropFirst().first else { Issue.record("\(calls)"); return }
    }

    /// Nick's laptop: the move must never come before the size has taken.
    @Test func aSizeNeverTakenLeavesThePositionAlone() {
        let (calls, end) = run(WindowSteps(target: narrowed, keep: .left), from: full, takesSize: false)
        #expect(end == full)
        #expect(!calls.contains { if case .position = $0 { true } else { false } })
    }

    /// Stopped at its minimum: moved only as far as keeps its far edge.
    @Test func aMinimumWidthKeepsTheFarEdge() {
        let (_, end) = run(WindowSteps(target: narrowed, keep: .left), from: full, least: 1900)
        #expect(end == CGRect(x: 156, y: 0, width: 1900, height: 1290))
    }

    @Test func wideningMovesFirstThenSizes() {
        let (calls, end) = run(WindowSteps(target: full, keep: .left), from: narrowed)
        #expect(end == full)
        guard case .position = calls.first, case .size = calls.dropFirst().first else { Issue.record("\(calls)"); return }
    }

    /// Moved first to widen, and the size not taken: back where it was.
    @Test func aWideningNotTakenIsMovedBack() {
        let (_, end) = run(WindowSteps(target: full, keep: .left), from: narrowed, takesSize: false)
        #expect(end == narrowed)
    }

    @Test func nothingToDoSendsNothing() {
        var s = WindowSteps(target: full, keep: nil)
        #expect(s.step(seen: full, now: 0) == nil && s.done)
    }
}
