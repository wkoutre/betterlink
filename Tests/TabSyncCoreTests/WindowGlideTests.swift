import CoreGraphics
import Testing
@testable import TabSyncCore

/// The browser moved with the slide, frame by frame, its far edge kept.
/// Each test plays a browser whose sets land at once (or late, or animated).
@Suite struct WindowGlideTests {
    private let closed = CGRect(x: 0, y: 0, width: 2056, height: 1290)
    private let leftOpen = CGRect(x: 280, y: 0, width: 1776, height: 1290)
    private let rightOpen = CGRect(x: 0, y: 0, width: 1776, height: 1290)

    /// A window that takes each call at once (down to `least` wide, never
    /// past `right`), ticked 120 times a second for the slide's eased 0.22 s.
    private struct Run {
        var frames: [CGRect] = []
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
            case .size(let f): w.size.width = max(least, min(f.width, (g.right ?? .infinity) - w.minX))
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
                if lateBy > 0 || animation > 0 { queue.append((t + max(lateBy, animation), call)) } else { apply(call, to: &r.window) }
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
        // A size and a position each tick, never more; and many frames, as the slide.
        #expect(r.callsPerTick.allSatisfy { $0 <= 2 })
        #expect(Set(r.frames.map(\.width)).count >= 20)
        guard case .size = r.calls[0], case .position = r.calls[1] else { Issue.record("\(r.calls.prefix(2))"); return }
    }

    @Test func aShowOnTheRightSendsSizesAlone() {
        let r = run(WindowGlide(closed: closed, open: rightOpen, side: .right, right: 2056, proven: true), from: closed, showing: true)
        #expect(r.window == rightOpen)
        #expect(r.calls.allSatisfy { if case .size = $0 { true } else { false } })
        #expect(r.frames.allSatisfy { $0.minX == 0 })
    }

    /// The hide against the screen's right edge can't grow in place: the
    /// position first, then the size, its far edge back by the end of the tick.
    @Test func aHideAgainstTheRightEdgeMovesFirst() {
        let r = run(WindowGlide(closed: closed, open: leftOpen, side: .left, right: 2056, proven: true), from: leftOpen, showing: false)
        #expect(r.window == closed)
        #expect(r.frames.allSatisfy { abs($0.maxX - 2056) < 0.5 })
        guard case .position = r.calls[0], case .size = r.calls[1] else { Issue.record("\(r.calls.prefix(2))"); return }
    }

    /// With room to grow in place, the size first, as narrowing: one frame live.
    @Test func aHideWithRoomGrowsInPlaceFirst() {
        let c = CGRect(x: 100, y: 0, width: 1000, height: 1290), o = CGRect(x: 380, y: 0, width: 720, height: 1290)
        let r = run(WindowGlide(closed: c, open: o, side: .left, right: 2056, proven: true), from: o, showing: false)
        #expect(r.window == c)
        #expect(r.frames.allSatisfy { abs($0.maxX - 1100) < 0.5 })
        guard case .size = r.calls[0] else { Issue.record("\(r.calls.prefix(2))"); return }
    }

    /// Brave's minimum: the width read back places the far edge exactly; once
    /// a size changes nothing the glide gives way to the steps, as after
    /// their own size (they check the stop short).
    @Test func aMinimumKeepsTheFarEdgeAndHandsOver() {
        let narrow = CGRect(x: 1256, y: 0, width: 800, height: 1259), opened = CGRect(x: 1536, y: 0, width: 520, height: 1259)
        let r = run(WindowGlide(closed: narrow, open: opened, side: .left, right: 2056, proven: true), from: narrow, showing: true, least: 615)
        #expect(r.window.width == 615 && r.window.maxX == 2056, "\(r.window)")
        #expect(r.frames.allSatisfy { abs($0.maxX - 2056) < 0.5 })
        guard case .holds = r.glide.handover(seen: r.window) else { Issue.record("\(r.glide.handover(seen: r.window))"); return }
    }

    /// Not yet proven: the first frame is a probe, the size alone, at least
    /// `probeStep`. Landed at once, the glide goes on with pairs.
    @Test func theProbeProvesTheSets() {
        let r = run(WindowGlide(closed: closed, open: leftOpen, side: .left, right: 2056, proven: false), from: closed, showing: true)
        #expect(r.glide.proven && r.window == leftOpen)
        guard case .size(let f) = r.calls[0], f.width == 2056 - WindowGlide.probeStep else { Issue.record("\(r.calls[0])"); return }
        // Landed: the far edge put back at the probe's width, then a size and a position each tick.
        guard case .position(let p) = r.calls[1], p.maxX == 2056, case .size = r.calls[2], case .position = r.calls[3] else {
            Issue.record("\(r.calls.prefix(4))"); return
        }
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
