// ftk <ms> <press-at-ms> <browser pid> <pid>...: samples every on-screen window of the given pids every ~2 ms for <ms>,
// printing each change (t ms, pid, window, frame); at <press-at-ms> sends betterlink's shortcut (control+option+S),
// only if the frontmost app is <browser pid> (else prints SKIPPED and sends nothing), and prints "PRESS t".
import AppKit
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let ms = Double(a[1])!, pressAt = Double(a[2])!, browser = Int32(a[3])!
let pids = Set(a.dropFirst(3).map { Int32($0)! })
var last: [Int: String] = [:]; let t0 = Date(); var pressed = false
func now() -> Double { Date().timeIntervalSince(t0) * 1000 }
while now() < ms {
    if !pressed, now() >= pressAt {
        pressed = true
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        if front == browser {
            let t = now()
            for d in [true, false] { let e = CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: d)!; e.flags = [.maskControl, .maskAlternate]; e.post(tap: .cghidEventTap); if d { usleep(30000) } }
            print(String(format: "PRESS %.1f", t))
        } else { print("SKIPPED front \(front)") }
    }
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var seen = Set<Int>()
    for w in l { guard let p = w[kCGWindowOwnerPID as String] as? Int32, pids.contains(p), let n = w[kCGWindowNumber as String] as? Int,
                   let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) > 60, (b["Height"] ?? 0) > 60 else { continue }
        seen.insert(n)
        let s = String(format: "pid %d win %d %.0f,%.0f %.0fx%.0f", p, n, b["X"]!, b["Y"]!, b["Width"]!, b["Height"]!)
        if last[n] != s { print(String(format: "%7.1f %@", now(), s)); last[n] = s } }
    for n in last.keys where !seen.contains(n) { print(String(format: "%7.1f win %d gone", now(), n)); last[n] = nil }
    usleep(2000)
}
