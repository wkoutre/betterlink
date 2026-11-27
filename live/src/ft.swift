// ft <ms> <pid>...: samples every on-screen window of the given pids every ~4 ms for <ms>, printing each change (t, pid, window, frame, alpha)
import CoreGraphics
import Foundation
let a = CommandLine.arguments; let ms = Double(a[1])!; let pids = Set(a.dropFirst(2).map { Int32($0)! })
var last: [Int: String] = [:]; let t0 = Date()
while Date().timeIntervalSince(t0) * 1000 < ms {
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var seen = Set<Int>()
    for w in l { guard let p = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(p), let n = w[kCGWindowNumber as String] as? Int,
                   let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) > 60, (b["Height"] ?? 0) > 60 else { continue }
        seen.insert(n)
        let s = String(format: "pid %d win %d %.0f,%.0f %.0fx%.0f a%.2f L%d", p, n, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!, (w[kCGWindowAlpha as String] as? Double) ?? 1, (w[kCGWindowLayer as String] as? Int) ?? 0)
        if last[n] != s { print(String(format: "%7.1f %@", Date().timeIntervalSince(t0) * 1000, s)); last[n] = s } }
    for n in last.keys where !seen.contains(n) { print(String(format: "%7.1f win %d gone", Date().timeIntervalSince(t0) * 1000, n)); last[n] = nil }
    usleep(4000)
}
