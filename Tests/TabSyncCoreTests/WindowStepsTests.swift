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

    /// Giving space back (`retreats` false), a size not taken leaves the
    /// window where it was put: a browser that answers late then takes it
    /// there, where macOS doesn't cut it short at the screen's edge.
    @Test func givingSpaceBackASizeNotTakenStaysWherePut() {
        var s = WindowSteps(target: full, keep: nil, retreats: false)
        var w = narrowed, t = 0.0
        while !s.done, t < 10 {
            if let c = s.step(seen: w, now: t), case .position(let f) = c { w.origin.x = f.minX }
            t += 1.0 / 120
        }
        #expect(w == CGRect(x: 0, y: 0, width: 1776, height: 1290))
    }

    /// Brave at its minimum (615 of 800 asked down to 520): the size is sent
    /// once, never again, and the steps end as soon as it has stopped.
    @Test func aMinimumIsNotAskedAgain() {
        let start = CGRect(x: 1256, y: 0, width: 800, height: 1259)
        let target = CGRect(x: 1536, y: 0, width: 520, height: 1259)
        let (calls, end) = run(WindowSteps(target: target, keep: .left), from: start, least: 615)
        #expect(end == CGRect(x: 1441, y: 0, width: 615, height: 1259))
        #expect(calls.filter { if case .size = $0 { true } else { false } }.count == 1, "\(calls)")
    }

    /// Opening, a stop short of `widest` ends the steps there: the window isn't moved to keep its far edge first.
    @Test func stoppingShortOfWidestEndsAtOnce() {
        let start = CGRect(x: 1256, y: 0, width: 800, height: 1259)
        var s = WindowSteps(target: CGRect(x: 1536, y: 0, width: 520, height: 1259), keep: .left, widest: 600)
        var w = start, t = 0.0, calls: [WindowSteps.Call] = []
        while !s.done, t < 2 {
            if let c = s.step(seen: w, now: t) {
                calls.append(c)
                if case .size(let f) = c { w.size.width = max(615, f.width) }
            }
            t += 1.0 / 120
        }
        #expect(s.stoppedShort && calls.count == 1 && t < WindowSteps.still + 0.05, "\(calls) in \(t) s")
    }

    /// Someone else moves the window while a call of a show or hide is out:
    /// nothing more is sent.
    @Test func aMoveByAnyoneElseEndsTheSteps() {
        var s = WindowSteps(target: narrowed, keep: .left, deadline: 3)
        #expect(s.step(seen: full, now: 0) == .size(narrowed))
        let moved = full.offsetBy(dx: -40, dy: -20) // its top left moved: no size call does that
        #expect(s.step(seen: moved, now: 0.01) == nil)
        #expect(s.done && s.interrupted)
    }

    /// A call still out when new steps take over is waited for first, not cut short.
    @Test func aCallInFlightIsWaitedForByTheStepsAfter() {
        var first = WindowSteps(target: narrowed, keep: .left)
        #expect(first.step(seen: full, now: 0) == .size(narrowed))
        var back = WindowSteps(target: full, keep: nil, after: first)
        #expect(back.step(seen: full, now: 0.01) == nil) // the size hasn't landed: nothing sent over it
        let landed = CGRect(x: 0, y: 0, width: 1776, height: 1290)
        #expect(back.step(seen: landed, now: 0.02) == nil)
        #expect(back.step(seen: landed, now: 0.04) == .size(full))
        #expect(!back.interrupted)
    }

    /// Without a deadline (a drag of the sidebar's edge) nothing is taken as
    /// someone else's: a change is the window's answer, and the steps go on from it.
    @Test func withoutADeadlineAChangeIsTheAnswer() {
        var s = WindowSteps(target: narrowed, keep: .left)
        #expect(s.step(seen: full, now: 0) == .size(narrowed))
        _ = s.step(seen: full.offsetBy(dx: -40, dy: -20), now: 0.01)
        #expect(!s.interrupted)
    }

    /// A call the window hasn't started on (macOS 27's animation can begin
    /// late; a browser can answer late) is not taken as not taken: it is
    /// sent again each `patience`, waited for, and only the deadline ends
    /// the wait (`capped`).
    @Test func aCallNotStartedIsWaitedForUpToTheDeadline() {
        var s = WindowSteps(target: narrowed, keep: .left, deadline: 3)
        var calls: [WindowSteps.Call] = [], t = 0.0
        while !s.done, t < 10 {
            if let c = s.step(seen: full, now: t) { calls.append(c) }
            t += 1.0 / 120
        }
        #expect(s.capped && !s.interrupted && abs(t - 3) < 0.02, "done at \(t)")
        #expect(calls.allSatisfy { $0 == .size(narrowed) } && calls.count == 5, "\(calls)")
    }

    /// The window starts late (here 0.4 s, then 0.2 s each way) and still
    /// ends where it was asked, each call waited for until it has landed.
    @Test func aWindowThatStartsLateIsWaitedFor() {
        var s = WindowSteps(target: narrowed, keep: .left, deadline: 3)
        var w = full, t = 0.0
        var due: [(at: Double, call: WindowSteps.Call)] = []
        while !s.done, t < 10 {
            if let i = due.firstIndex(where: { $0.at <= t }) {
                switch due.remove(at: i).call {
                case .size(let f): w = CGRect(x: w.minX, y: w.maxY - f.height, width: f.width, height: f.height)
                case .position(let f): w.origin = CGPoint(x: f.minX, y: f.maxY - w.height)
                }
            }
            if let c = s.step(seen: w, now: t) { due.append((t + 0.4, c)) }
            t += 1.0 / 120
        }
        #expect(w == narrowed && !s.capped && !s.interrupted, "\(w) at \(t)")
    }

    /// A window that moves, then holds still, has landed where it stopped:
    /// after `still`, not before.
    @Test func aChangeThatHoldsStillHasLanded() {
        var s = WindowSteps(target: narrowed, keep: .left, deadline: 3)
        #expect(s.step(seen: full, now: 0) == .size(narrowed))
        let stopped = CGRect(x: 0, y: 0, width: 1900, height: 1290)
        #expect(s.step(seen: stopped, now: 0.05) == nil)
        #expect(s.step(seen: stopped, now: 0.05 + WindowSteps.still - 0.01) == nil)
        #expect(s.step(seen: stopped, now: 0.05 + WindowSteps.still + 0.01) == .position(CGRect(x: 156, y: 0, width: 1900, height: 1290)))
    }

    /// The final target sent whole (`resends`), even where the window is
    /// already: a browser that does its calls in order, however late, ends
    /// there, though calls sent before are still on their way.
    @Test func theFinalTargetIsSentWholeAndLandsLast() {
        // A late browser: every call waits in a queue, done in order 2 s after the first.
        var queue: [WindowSteps.Call] = [.size(narrowed)] // an open's size, cut off by the cap
        var r = WindowSteps(target: full, keep: nil, resends: true)
        var w = full, t = 0.0
        while !r.done, t < 10 {
            if let c = r.step(seen: w, now: t) { queue.append(c) }
            t += 1.0 / 120
        }
        // Each sent twice: the window looks there already, so a call's landing can't be seen (a call can be dropped).
        #expect(Array(queue.dropFirst()) == [.position(full), .position(full), .size(full), .size(full)], "\(queue)")
        for c in queue {
            switch c {
            case .size(let f): w = CGRect(x: w.minX, y: w.maxY - f.height, width: f.width, height: f.height)
            case .position(let f): w.origin = CGPoint(x: f.minX, y: f.maxY - w.height)
            }
        }
        #expect(w == full, "\(w)")
        #expect(t <= 2 * WindowSteps.timeout + 0.05, "the re-send waited \(t) s")
    }

    @Test func nothingToDoSendsNothing() {
        var s = WindowSteps(target: full, keep: nil)
        #expect(s.step(seen: full, now: 0) == nil && s.done)
    }
}
