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
                case .frame(let f): w = takesSize ? CGRect(x: f.minX, y: f.minY, width: max(least, f.width), height: f.height) : CGRect(origin: CGPoint(x: f.minX, y: f.maxY - w.height), size: w.size)
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
        #expect(s.stoppedShort && t < 2 * WindowSteps.still + 0.05, "\(calls) in \(t) s")
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
                case .frame(let f): w = f
                }
            }
            if let c = s.step(seen: w, now: t) { due.append((t + 0.4, c)) }
            t += 1.0 / 120
        }
        #expect(w == narrowed && !s.capped && !s.interrupted, "\(w) at \(t)")
    }

    /// A window that moves, then holds still short of what was asked, is
    /// sent the call once more after `still` (a hold partway through an
    /// animation); still another `still` (plus the 50 ms the window took to
    /// start on the call), it has landed where it stopped.
    @Test func aChangeThatHoldsStillHasLanded() {
        var s = WindowSteps(target: narrowed, keep: .left, deadline: 3)
        #expect(s.step(seen: full, now: 0) == .size(narrowed))
        let stopped = CGRect(x: 0, y: 0, width: 1900, height: 1290)
        let t = 0.05 + WindowSteps.still
        #expect(s.step(seen: stopped, now: 0.05) == nil)
        #expect(s.step(seen: stopped, now: t - 0.01) == nil)
        #expect(s.step(seen: stopped, now: t + 0.01) == .size(narrowed))
        #expect(s.step(seen: stopped, now: t + WindowSteps.still + 0.04) == nil)
        #expect(s.step(seen: stopped, now: t + WindowSteps.still + 0.07) == .position(CGRect(x: 156, y: 0, width: 1900, height: 1290)))
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
            case .frame(let f): w = f
            }
        }
        #expect(w == full, "\(w)")
        #expect(t <= 2 * WindowSteps.timeout + 0.05, "the re-send waited \(t) s")
    }

    /// Review of 596bc4e, F1, the reviewer's probe: an animated narrowing
    /// that stands still partway (2056 to 1900 in 0.1 s, still until
    /// 0.35 s, on to 1776 by 0.45 s) has not stopped short: the steps end
    /// where they were asked, not at 1900.
    @Test func aHoldPartwayIsNotAStopShort() {
        let target = CGRect(x: 280, y: 0, width: 1776, height: 1290)
        var s = WindowSteps(target: target, keep: .left, widest: full.width - 200, deadline: 3)
        var w = full, t = 0.0, sizeAt: Double?
        while !s.done, t < 3.5 {
            if let a = sizeAt {
                let u = t - a
                let width: CGFloat = u < 0.1 ? 2056 - 1560 * CGFloat(u) : (u < 0.35 ? 1900 : max(1776, 1900 - 1240 * CGFloat(u - 0.35)))
                w.size.width = width.rounded()
            }
            if let c = s.step(seen: w, now: t) {
                if case .size = c, sizeAt == nil { sizeAt = t }
                if case .position(let f) = c { w.origin.x = f.minX; sizeAt = nil }
            }
            t += 1.0 / 120
        }
        #expect(!s.stoppedShort && !s.capped && w == target, "stopped short \(s.stoppedShort), at \(w)")
    }

    /// A size that stops short and stays there, sent once more, has stopped:
    /// the steps end within two waits of `still`, never at the deadline.
    @Test func aStopShortIsCheckedOnceThenTaken() {
        let start = CGRect(x: 1256, y: 0, width: 800, height: 1259)
        var s = WindowSteps(target: CGRect(x: 1536, y: 0, width: 520, height: 1259), keep: .left, widest: 600, deadline: 3)
        var w = start, t = 0.0, sizes = 0
        while !s.done, t < 3.5 {
            if let c = s.step(seen: w, now: t), case .size(let f) = c { sizes += 1; w.size.width = max(615, f.width) }
            t += 1.0 / 120
        }
        #expect(s.stoppedShort && sizes == 2 && t < 2 * WindowSteps.still + 0.05, "\(sizes) sizes, done at \(t)")
    }

    /// Review of ce5bf39, F5, the reviewer's probe: a show's size held still
    /// short (1950 of the 1776 asked), and a hide pressed before the show
    /// checked it (`after:`, with a deadline, or the final target sent whole
    /// on quitting). The steps after take over the call in flight but never
    /// send it again: it is the show's, and the last press wins. The hide's
    /// first call is its own widening, and no size of the show's follows the press.
    @Test func stepsAfterOthersNeverSendTheirCallAgain() {
        let held = CGRect(x: 0, y: 0, width: 1950, height: 1290)
        for resends in [false, true] {
            var show = WindowSteps(target: narrowed, keep: .left, widest: full.width - 200, deadline: 3)
            #expect(show.step(seen: full, now: 0) == .size(narrowed))
            #expect(show.step(seen: held, now: 0.05) == nil)
            var hide = resends ? WindowSteps(target: full, keep: nil, resends: true, after: show)
                               : WindowSteps(target: full, keep: .left, retreats: false, deadline: 3.1, after: show)
            var w = held, t = 0.1, calls: [(t: Double, call: WindowSteps.Call)] = []
            while !hide.done, t < 4 {
                if let c = hide.step(seen: w, now: t) {
                    calls.append((t, c))
                    switch c {
                    case .size(let f): w = CGRect(x: w.minX, y: w.maxY - f.height, width: f.width, height: f.height)
                    case .position(let f): w.origin = CGPoint(x: f.minX, y: f.maxY - w.height)
                    case .frame(let f): w = f
                    }
                }
                t += 1.0 / 120
            }
            let text = calls.map { String(format: "%.3f: %@", $0.t, "\($0.call)") }.joined(separator: ", ")
            #expect(!calls.contains { $0.call == .size(narrowed) }, "resends \(resends): \(text)")
            #expect(resends || calls.first?.call == .size(full), "resends \(resends): \(text)")
            #expect(w == full && !hide.interrupted, "resends \(resends): at \(w), \(text)")
        }
    }

    /// The same with a show's call the window hasn't started on: the hide
    /// waits for it up to its deadline, and never sends it again (it may yet
    /// land, and the hide's calls are worked out from where the window is).
    @Test func aCallTakenOverThatHasNotStartedIsNeverSentAgain() {
        var show = WindowSteps(target: narrowed, keep: .left, deadline: 3)
        #expect(show.step(seen: full, now: 0) == .size(narrowed))
        var hide = WindowSteps(target: full, keep: .left, retreats: false, deadline: 3.1, after: show)
        var calls: [WindowSteps.Call] = [], t = 0.1
        while !hide.done, t < 4 {
            if let c = hide.step(seen: full, now: t) { calls.append(c) }
            t += 1.0 / 120
        }
        #expect(calls.isEmpty, "\(calls)")
    }

    /// The mini at ce5bf39: Brave at its own minimum (615 pt), asked for 335,
    /// never moves. With nothing seen of its minimum the size is waited for
    /// up to the deadline (it may be late). This window's browser seen
    /// before to stop at 615 (`stops`), the size is sent once more after
    /// `still` unmoved and, still unmoved another `still`, it has stopped
    /// there: the steps end `stoppedShort`, not at the deadline. Wider than
    /// that (800 pt), what was seen says nothing, and it is waited for.
    @Test func aWindowSeenToStopThereIsTakenAsStoppedWhenItDoesntMove() {
        let target = CGRect(x: 1721, y: 0, width: 335, height: 1259)
        for (stops, width) in [(nil, 615), (615, 615), (615, 800)] as [(CGFloat?, CGFloat)] {
            let start = CGRect(x: target.maxX - width, y: 0, width: width, height: 1259)
            var s = WindowSteps(target: target, keep: .left, widest: width - 200, deadline: 3, stops: stops)
            var t = 0.0, sizes = 0
            while !s.done, t < 3.5 {
                if let c = s.step(seen: start, now: t), case .size = c { sizes += 1 }
                t += 1.0 / 120
            }
            let text = "stops \(stops.map { "\(Int($0))" } ?? "nil"), \(Int(width)) wide: \(sizes) sizes, done at \(t), capped \(s.capped), short \(s.stoppedShort)"
            if stops != nil, width == 615 {
                #expect(s.stoppedShort && !s.capped && sizes == 2 && t < 2 * WindowSteps.still + 0.05, "\(text)")
            } else {
                #expect(s.capped && !s.stoppedShort, "\(text)")
            }
        }
    }

    /// A slide-over's one set, sent by the caller (`init(sending:)`): a
    /// browser that takes it at once is done once it has landed, with nothing
    /// more sent (`clean`), either side, narrowing or widening.
    @Test func oneSetThatLandsAtOnceIsAllThereIs() {
        for (from, to, keep) in [(full, narrowed, SidebarSide.left), (narrowed, full, .left), (full, CGRect(x: 0, y: 0, width: 1776, height: 1290), .right)] {
            let calls = WindowSet.calls(from: from, to: to, keep: keep, right: 2056)
            let call: WindowSteps.Call = calls.count > 1 ? .frame(to) : calls[0]
            var s = WindowSteps(target: to, keep: keep, deadline: 3, sending: call, from: from, at: 0)
            var t = 1.0 / 120, more: [WindowSteps.Call] = []
            while !s.done, t < 4 {
                if let c = s.step(seen: to, now: t) { more.append(c) }
                t += 1.0 / 120
            }
            #expect(s.clean && more.isEmpty && t < 0.3, "\(from) to \(to): clean \(s.clean), sent \(more), done at \(t)")
        }
    }

    /// The set stopped at the browser's minimum (1830 of 1776 asked, on the
    /// left: the window moved 280 and took 1830, its far edge out): it is
    /// checked once more, then the far edge put back at the width it took.
    /// Not clean: the final frame is owed.
    @Test func oneSetStoppedAtAMinimumIsFinishedByTheSteps() {
        var w = CGRect(x: 280, y: 0, width: 1830, height: 1290)
        var s = WindowSteps(target: narrowed, keep: .left, widest: full.width - 200, deadline: 3, sending: .frame(narrowed), from: full, at: 0)
        var t = 1.0 / 120, calls: [WindowSteps.Call] = []
        while !s.done, t < 4 {
            if let c = s.step(seen: w, now: t) {
                calls.append(c)
                if case .position(let f) = c { w.origin.x = f.minX }
            }
            t += 1.0 / 120
        }
        #expect(w == CGRect(x: 226, y: 0, width: 1830, height: 1290) && !s.clean && !s.interrupted && !s.stoppedShort, "at \(w), \(calls)")
    }

    /// A move by someone else while the set is on its way ends the steps
    /// (the top edge moved): nothing more is sent.
    @Test func someoneElsesMoveDuringTheSetEndsIt() {
        var s = WindowSteps(target: narrowed, keep: .left, deadline: 3, sending: .frame(narrowed), from: full, at: 0)
        #expect(s.step(seen: full.offsetBy(dx: 0, dy: -40), now: 0.01) == nil)
        #expect(s.done && s.interrupted)
    }

    @Test func nothingToDoSendsNothing() {
        var s = WindowSteps(target: full, keep: nil)
        #expect(s.step(seen: full, now: 0) == nil && s.done)
    }
}
