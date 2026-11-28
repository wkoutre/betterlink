import CoreGraphics
import Testing
@testable import TabSyncCore

/// The browser moved with the slide, frame by frame, its far edge kept.
/// Each test plays a browser whose sets land at once (or late, or animated).
@Suite struct WindowGlideTests {
    private let closed = CGRect(x: 0, y: 0, width: 2056, height: 1290)
    private let leftOpen = CGRect(x: 280, y: 0, width: 1776, height: 1290)
    private let rightOpen = CGRect(x: 0, y: 0, width: 1776, height: 1290)

    /// A window that takes each call at once (down to `least` wide; while it
    /// is wholly on screen, never wider than reaches `right`, as Chromium),
    /// ticked 120 times a second for the slide's eased 0.22 s.
    private struct Run {
        var frames: [CGRect] = []
        /// The window after every call: live, the window server can show any
        /// one of them alone for a refresh.
        var states: [CGRect] = []
        var callsPerTick: [Int] = []
        var calls: [WindowSteps.Call] = []
        var glide: WindowGlide
        var window: CGRect
    }

    private func run(_ g: WindowGlide, from start: CGRect, showing: Bool, least: CGFloat = 1, lateBy: Double = 0, animation: Double = 0) -> Run {
        var r = Run(glide: g, window: start)
        var queue: [(at: Double, call: WindowSteps.Call)] = []
        var slide = SidebarSlide(shown: !showing)
        if showing { slide.show(at: 0, reduceMotion: false) } else { slide.hide(at: 0, reduceMotion: false) }
        var t = 0.0
        func apply(_ c: WindowSteps.Call, to w: inout CGRect) {
            switch c {
            case .size(let f):
                let room = w.maxX > (g.right ?? .infinity) + 0.5 ? CGFloat.infinity : (g.right ?? .infinity) - w.minX
                w.size.width = max(least, min(f.width, room))
            case .position(let f): w.origin.x = f.minX
            }
        }
        while !r.glide.done, t < 3 {
            // What was sent late lands now (or, animated, the last one lands whole after `animation`).
            for q in queue where t >= q.at { apply(q.call, to: &r.window) }
            queue.removeAll { t >= $0.at }
            var c = r.glide.step(seen: r.window, now: t, progress: slide.progress(at: t), end: slide.done(at: t), deadline: 3)
            var n = 0
            while let call = c {
                n += 1
                r.calls.append(call)
                if lateBy > 0 || animation > 0 { queue.append((t + max(lateBy, animation), call)) } else { apply(call, to: &r.window); r.states.append(r.window) }
                var w: CGFloat?
                if case .size = call, lateBy == 0, animation == 0 { w = r.window.width }
                if case .size = call, animation > 0 { w = r.window.width } // read back before the animation shows it
                c = r.glide.next(width: w)
            }
            r.callsPerTick.append(n)
            r.frames.append(r.window)
            t += 1.0 / 120
        }
        return r
    }

    @Test func aShowOnTheLeftKeepsTheFarEdgeEveryTick() {
        let r = run(WindowGlide(closed: closed, open: leftOpen, side: .left, right: 2056, proven: true), from: closed, showing: true)
        #expect(r.glide.done && !r.glide.interrupted && !r.glide.slow)
        #expect(r.window == leftOpen)
        #expect(r.frames.allSatisfy { abs($0.maxX - 2056) < 0.5 }, "\(r.frames.map(\.maxX))")
        // Never in at any call: the position first, its far edge past the screen's edge until the size lands
        // (0.3.37: the size first, the far edge in by a step until the position landed; 47 pt median live).
        #expect(r.states.allSatisfy { $0.maxX >= 2056 - 0.5 }, "\(r.states.map(\.maxX))")
        // A position and a size each tick, never more; and many frames, as the slide.
        #expect(r.callsPerTick.allSatisfy { $0 <= 2 })
        #expect(Set(r.frames.map(\.width)).count >= 20)
        guard case .position = r.calls[0], case .size = r.calls[1] else { Issue.record("\(r.calls.prefix(2))"); return }
    }

    @Test func aShowOnTheRightSendsSizesAlone() {
        let r = run(WindowGlide(closed: closed, open: rightOpen, side: .right, right: 2056, proven: true), from: closed, showing: true)
        #expect(r.window == rightOpen)
        #expect(r.calls.allSatisfy { if case .size = $0 { true } else { false } })
        #expect(r.frames.allSatisfy { $0.minX == 0 })
    }

    /// The hide against the screen's right edge: a window wholly on screen
    /// can't grow past it, so it is first moved a point past it, then each
    /// tick grows past it and is moved back to a point past, its far edge
    /// never in (0.3.37: the position first, the far edge in by a step until
    /// the size landed). The last frame puts it exactly where it was.
    @Test func aHideAgainstTheRightEdgeGoesPastItFirst() {
        let r = run(WindowGlide(closed: closed, open: leftOpen, side: .left, right: 2056, proven: true), from: leftOpen, showing: false)
        #expect(r.window == closed)
        #expect(r.frames.allSatisfy { abs($0.maxX - 2056) < 1.5 }, "\(r.frames.map(\.maxX))")
        #expect(r.states.allSatisfy { $0.maxX >= 2056 - 0.5 }, "\(r.states.map(\.maxX))")
        guard case .position(let p) = r.calls[0], p.minX == leftOpen.minX + 1, p.width == leftOpen.width, case .size = r.calls[1] else {
            Issue.record("\(r.calls.prefix(2))"); return
        }
        #expect(Set(r.frames.map(\.width)).count >= 20)
    }

    /// With room to grow in place, the size first, as narrowing: one frame live.
    @Test func aHideWithRoomGrowsInPlaceFirst() {
        let c = CGRect(x: 100, y: 0, width: 1000, height: 1290), o = CGRect(x: 380, y: 0, width: 720, height: 1290)
        let r = run(WindowGlide(closed: c, open: o, side: .left, right: 2056, proven: true), from: o, showing: false)
        #expect(r.window == c)
        #expect(r.frames.allSatisfy { abs($0.maxX - 1100) < 0.5 })
        #expect(r.states.allSatisfy { $0.maxX >= 1100 - 0.5 }, "\(r.states.map(\.maxX))")
        guard case .size = r.calls[0] else { Issue.record("\(r.calls.prefix(2))"); return }
    }

    /// Brave's minimum: the width read back places the far edge exactly; once
    /// a size changes nothing the glide gives way to the steps, as after
    /// their own size (they check the stop short).
    @Test func aMinimumKeepsTheFarEdgeAndHandsOver() {
        let narrow = CGRect(x: 1256, y: 0, width: 800, height: 1259), opened = CGRect(x: 1536, y: 0, width: 520, height: 1259)
        let r = run(WindowGlide(closed: narrow, open: opened, side: .left, right: 2056, proven: true), from: narrow, showing: true, least: 615)
        #expect(r.window.width == 615 && r.window.maxX == 2056, "\(r.window)")
        #expect(r.states.allSatisfy { $0.maxX >= 2056 - 0.5 }, "\(r.states.map(\.maxX))")
        #expect(r.frames.allSatisfy { abs($0.maxX - 2056) < 0.5 })
        guard case .holds = r.glide.handover(seen: r.window) else { Issue.record("\(r.glide.handover(seen: r.window))"); return }
    }

    /// Already at its minimum: the position sent first takes, the size
    /// changes nothing, its far edge out, never in. Once that shows (not
    /// within `instant`: the read can be behind the window), the glide hands
    /// over as after a size, and the steps put the far edge back at the width
    /// the window kept (SidebarGuardTests.aWindowAtItsBrowsersMinimum).
    @Test func aShowAtTheMinimumAlreadyHandsOverAsAfterASize() {
        let narrow = CGRect(x: 1441, y: 0, width: 615, height: 1259), opened = CGRect(x: 1721, y: 0, width: 335, height: 1259)
        let r = run(WindowGlide(closed: narrow, open: opened, side: .left, right: 2056, proven: true), from: narrow, showing: true, least: 615)
        #expect(r.window.width == 615, "\(r.window)")
        #expect(r.states.allSatisfy { $0.maxX >= 2056 - 0.5 }, "\(r.states.map(\.maxX))")
        #expect(r.glide.done && !r.glide.interrupted)
        guard case .holds = r.glide.handover(seen: r.window) else { Issue.record("\(r.glide.handover(seen: r.window))"); return }
    }

    /// Not yet proven: the first frame is a probe, the size alone, at least
    /// `probeStep` (its far edge that far in until it shows: the one call
    /// that brings it in, once per window until its sets are seen to land at
    /// once). Landed at once, the glide goes on: on the left, the far edge
    /// put back, then a position and a size each tick, never in.
    @Test func theProbeProvesTheSets() {
        let r = run(WindowGlide(closed: closed, open: leftOpen, side: .left, right: 2056, proven: false), from: closed, showing: true)
        #expect(r.glide.proven && r.window == leftOpen)
        guard case .size(let f) = r.calls[0], f.width == 2056 - WindowGlide.probeStep else { Issue.record("\(r.calls[0])"); return }
        guard case .position(let p) = r.calls[1], p.maxX == 2056 else { Issue.record("\(r.calls.prefix(4))"); return }
        #expect(r.states.dropFirst().allSatisfy { $0.maxX >= 2056 - 0.5 }, "\(r.states.map(\.maxX))")
        // Never back: the window only narrows.
        #expect(zip(r.frames, r.frames.dropFirst()).allSatisfy { $1.width <= $0.width }, "\(r.frames.map(\.width).prefix(8))")
    }

    /// Sets animated over 250 ms (the enhanced UI on and stuck, or a macOS
    /// that animates anyway): the probe doesn't show within `instant`, no
    /// position follows it, and the steps start afresh.
    @Test func anAnimatedProbeGivesWay() {
        let r = run(WindowGlide(closed: closed, open: leftOpen, side: .left, right: 2056, proven: false), from: closed, showing: true, animation: 0.25)
        #expect(r.glide.slow && !r.glide.proven)
        #expect(r.calls.count == 1, "\(r.calls)")
        guard case .none = r.glide.handover(seen: r.window) else { Issue.record("\(r.glide.handover(seen: r.window))"); return }
    }

    /// Moved by someone else between two frames: nothing more is sent.
    @Test func someoneElsesMoveInterrupts() {
        var g = WindowGlide(closed: closed, open: leftOpen, side: .left, right: 2056, proven: true)
        var w = closed
        var t = 0.0
        var slide = SidebarSlide(shown: false)
        slide.show(at: 0, reduceMotion: false)
        for _ in 0..<6 {
            var c = g.step(seen: w, now: t, progress: slide.progress(at: t), end: false, deadline: 3)
            while let call = c {
                switch call {
                case .size(let f): w.size.width = f.width
                case .position(let f): w.origin.x = f.minX
                }
                c = g.next(width: w.width)
            }
            t += 1.0 / 120
        }
        w.origin.y += 40 // the person drags it down
        #expect(g.step(seen: w, now: t, progress: slide.progress(at: t), end: false, deadline: 3) == nil)
        #expect(g.done && g.interrupted)
    }
}
