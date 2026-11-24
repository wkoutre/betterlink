import AppKit
import CoreGraphics
import BetterlinkCore
import Foundation

/// Diagnostics, on only with BETTERLINK_TRACE=1: during a real window drag,
/// samples the window server every 4 ms off the main thread and reports how far
/// the sidebar panel trailed the browser window; logs every show and hide.
/// Lines go to trace.log in betterlink's settings folder.
enum DragTrace {
    static let enabled = ProcessInfo.processInfo.environment["BETTERLINK_TRACE"] == "1"
    /// trace.log in betterlink's settings folder (review F2).
    private static let file: URL = SettingsFolder.resolve().directory.appendingPathComponent("trace.log")
    private static let queue = DispatchQueue(label: "betterlink.dragtrace")
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var samples: [(t: Double, browser: CGRect, panel: CGRect)] = []

    static func log(_ line: String) {
        guard enabled else { return }
        let s = String(format: "%.3f ", Date().timeIntervalSince1970) + line + "\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: file) { h.seekToEndOfFile(); h.write(Data(s.utf8)); try? h.close() }
            else { try? Data(s.utf8).write(to: file) }
        }
    }

    /// Starts sampling the browser window `browser` and the panel `panel`.
    static func begin(browser: UInt32, panel: Int) {
        guard enabled else { return }
        queue.async {
            guard timer == nil else { return }
            samples = []
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(4))
            t.setEventHandler {
                // The API takes raw CGWindowIDs in the array's pointer slots, not
                // NSNumbers (a bridged Swift array returns nothing; review F1).
                var raw: [UnsafeRawPointer?] = [browser, UInt32(panel)].map { UnsafeRawPointer(bitPattern: UInt($0)) }
                guard let ids = CFArrayCreate(nil, &raw, raw.count, nil),
                      let info = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] else { return }
                var b: CGRect?, p: CGRect?
                for w in info {
                    let n = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                    guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                          let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else { continue }
                    if n == browser { b = r } else if n == UInt32(panel) { p = r }
                }
                if let b, let p { samples.append((Date().timeIntervalSince1970, b, p)) }
            }
            timer = t
            t.resume()
        }
    }

    /// Stops sampling and logs the drag: trail in points (how far the panel's
    /// move lagged the browser's) and, from the browser's speed, in ms.
    static func end() {
        guard enabled else { return }
        queue.async {
            guard let t = timer else { return }
            t.cancel(); timer = nil
            guard let first = samples.first, samples.count > 2 else { return }
            var trails: [Double] = [], lags: [Double] = []
            for i in 1..<samples.count {
                let s = samples[i], prev = samples[i - 1]
                let trail = abs((s.panel.minX - first.panel.minX) - (s.browser.minX - first.browser.minX))
                    + abs((s.panel.minY - first.panel.minY) - (s.browser.minY - first.browser.minY))
                trails.append(trail)
                let dt = (s.t - prev.t) * 1000
                let speed = hypot(s.browser.minX - prev.browser.minX, s.browser.minY - prev.browser.minY) / max(dt, 0.1)
                if speed > 0.05 { lags.append(trail / speed) }
            }
            func p(_ a: [Double], _ q: Double) -> Double { let s = a.sorted(); return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * q))] }
            let moved = hypot(samples.last!.browser.minX - first.browser.minX, samples.last!.browser.minY - first.browser.minY)
            log(String(format: "drag: %d samples over %.0f ms, moved %.0f pt, trail pt mean %.1f p95 %.1f max %.1f, lag ms p50 %.1f p95 %.1f, browser %@, panel %@",
                       samples.count, (samples.last!.t - first.t) * 1000, moved,
                       trails.reduce(0, +) / Double(trails.count), p(trails, 0.95), trails.max() ?? 0,
                       p(lags, 0.5), p(lags, 0.95), NSStringFromRect(first.browser), NSStringFromRect(first.panel)))
        }
    }
}
