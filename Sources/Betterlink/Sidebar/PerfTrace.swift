import AppKit
import QuartzCore

/// Diagnostics, on only with BETTERLINK_TRACE=1 (as DragTrace): what the main
/// thread does after a click in a sidebar panel. From a press in a panel until
/// 1.5 s after the last one it notes every display frame, every turn of the
/// main run loop and the work named with `span` and `count`, then writes them
/// to trace.log as one block of `perf:` lines.
///
/// Times are uptime, the clock NSEvent stamps events with, so a tool that
/// posts the click or records the screen can set its own times against them.
/// A frame that took longer than one refresh is one the main thread missed:
/// the display link is served by the main run loop, as SwiftUI's animations are.
@MainActor
enum PerfTrace {
    static let enabled = DragTrace.enabled

    /// How long after the last press in a panel the watch goes on.
    private static let watch = 1.5
    /// Turns of the run loop shorter than this aren't listed (ms).
    private static let turnWorthListing = 4.0

    private struct Entry { var at: Double; var ms: Double?; var name: String }
    private static var entries: [Entry] = []
    private static var counts: [String: (n: Int, ms: Double)] = [:]
    private static var frames: [(vsync: Double, called: Double)] = []
    private static var turns: [(began: Double, ended: Double)] = []
    /// Mouse ups in a panel: when the event was stamped and when it arrived.
    private static var ups: [(stamped: Double, arrived: Double)] = []
    private static var publishes: [Double] = []
    private static var until = 0.0
    private static var period = 1.0 / 60
    private static var link: CADisplayLink?
    private static var observer: CFRunLoopObserver?
    private static var turnBegan: Double?
    private static let ticker = Ticker()

    static var now: Double { CACurrentMediaTime() }
    private static var watching: Bool { link != nil }

    // MARK: - What is noted

    /// A press or release of the mouse in a sidebar panel, before it is handled.
    static func mouse(_ event: NSEvent) {
        guard enabled, event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
        let t = now
        begin(at: t)
        let up = event.type == .leftMouseUp
        if up { ups.append((event.timestamp, t)) }
        entries.append(Entry(at: t, ms: nil, name: String(format: "mouse %@, stamped %.1f ms earlier", up ? "up" : "down", (t - event.timestamp) * 1000)))
    }

    /// Runs `body`, noting how long it took.
    static func span<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let began = now
        defer {
            let ms = (now - began) * 1000
            if watching {
                entries.append(Entry(at: began, ms: ms, name: name))
            } else if ms >= turnWorthListing {
                DragTrace.log(String(format: "perf: %@ %.1f ms, with no click being watched", name, ms))
            }
        }
        return try body()
    }

    /// Something that happened, with no length of its own.
    static func mark(_ name: String) {
        guard enabled, watching else { return }
        entries.append(Entry(at: now, ms: nil, name: name))
    }

    /// The library the sidebars draw was published: the change a click asked
    /// for is on its way to the screen.
    static func published() {
        guard enabled, watching else { return }
        publishes.append(now)
        entries.append(Entry(at: now, ms: nil, name: "library published"))
    }

    /// For work too frequent to list: `began()` before, `ended` after. They
    /// are counted and summed. `timed: false` counts without adding its time
    /// (a call inside another one of the same name).
    static func began() -> Double { enabled && watching ? now : 0 }
    static func ended(_ name: String, _ began: Double, timed: Bool = true) {
        guard began > 0, watching else { return }
        var c = counts[name] ?? (0, 0)
        c.n += 1
        if timed { c.ms += (now - began) * 1000 }
        counts[name] = c
    }

    static func count(_ name: String) {
        guard enabled, watching else { return }
        counts[name, default: (0, 0)].n += 1
    }

    // MARK: - Watching

    private final class Ticker: NSObject {
        @objc func tick(_ link: CADisplayLink) {
            let vsync = link.timestamp, period = link.duration
            MainActor.assumeIsolated { PerfTrace.frame(vsync: vsync, period: period) }
        }
    }

    private static func begin(at t: Double) {
        until = t + watch
        guard link == nil, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        entries = []; counts = [:]; frames = []; turns = []; ups = []; publishes = []
        turnBegan = t
        let l = screen.displayLink(target: ticker, selector: #selector(Ticker.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        // After everything else that runs before the loop sleeps (Core
        // Animation's commit among it), so a turn's length holds its drawing.
        let o = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
                                                   true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated {
                let t = PerfTrace.now
                if activity == .afterWaiting { turnBegan = t }
                else if let began = turnBegan { turns.append((began, t)); turnBegan = nil }
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
        observer = o
    }

    private static func frame(vsync: Double, period: Double) {
        let t = now
        if period > 0 { self.period = period }
        frames.append((vsync, t))
        if t > until { end() }
    }

    private static func end() {
        link?.invalidate(); link = nil
        if let o = observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes); observer = nil }
        guard let zero = entries.map(\.at).min() else { return }
        func at(_ t: Double) -> String { String(format: "%+8.1f", (t - zero) * 1000) }
        var lines: [(Double, String)] = entries.map { e in
            (e.at, at(e.at) + " " + e.name + (e.ms.map { String(format: " %.2f ms", $0) } ?? ""))
        }
        for t in turns where (t.ended - t.began) * 1000 >= turnWorthListing {
            lines.append((t.began, at(t.began) + String(format: " turn of the run loop %.1f ms", (t.ended - t.began) * 1000)))
        }
        var intervals: [Double] = []
        for i in frames.indices.dropFirst() {
            let took = frames[i].vsync - frames[i - 1].vsync
            intervals.append(took * 1000)
            if took > period * 1.5 {
                lines.append((frames[i - 1].vsync, at(frames[i - 1].vsync) + String(format: " frame %.1f ms (%.1f refreshes), the next one called %.1f ms after its refresh",
                                                                               took * 1000, took / period, (frames[i].called - frames[i].vsync) * 1000)))
            }
        }
        DragTrace.log(String(format: "perf: watched %.0f ms from uptime %.6f, %d mouse up(s); times below are ms after that",
                             (now - zero) * 1000, zero, ups.count))
        for l in lines.sorted(by: { $0.0 < $1.0 }) { DragTrace.log("perf: " + l.1) }
        for (i, up) in ups.enumerated() {
            let next = i + 1 < ups.count ? ups[i + 1].arrived : .infinity
            guard let published = publishes.first(where: { $0 >= up.arrived && $0 < next }) else {
                DragTrace.log("perf: mouse up \(i + 1) at \(at(up.arrived)): nothing published")
                continue
            }
            // Drawn when the turn that published ends; on the screen at a refresh after that.
            let drawn = turns.first { $0.ended >= published }?.ended
            let refresh = drawn.flatMap { d in frames.first { $0.vsync >= d }?.vsync }
            DragTrace.log(String(format: "perf: mouse up %d at %@: stamped to published %.1f ms, to drawn %@ ms, to the next refresh %@ ms",
                                 i + 1, at(up.arrived), (published - up.stamped) * 1000,
                                 drawn.map { String(format: "%.1f", ($0 - up.stamped) * 1000) } ?? "?",
                                 refresh.map { String(format: "%.1f", ($0 - up.stamped) * 1000) } ?? "?"))
        }
        if !counts.isEmpty {
            DragTrace.log("perf: counted " + counts.sorted { $0.key < $1.key }
                .map { String(format: "%@ %d (%.1f ms)", $0.key, $0.value.n, $0.value.ms) }.joined(separator: ", "))
        }
        let long = intervals.filter { $0 > period * 1500 }
        DragTrace.log(String(format: "perf: %d frames of %.2f ms, longest %.1f ms, %d over 1.5 refreshes; each: %@",
                             intervals.count, period * 1000, intervals.max() ?? 0, long.count,
                             intervals.map { String(format: "%.0f", $0) }.joined(separator: " ")))
    }
}
