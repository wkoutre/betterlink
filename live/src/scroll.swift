// scroll <x> <y> <lines> <pid>...: posts scroll-wheel events at a point (negative lines scroll down), without moving focus.
// Refuses unless the topmost window at that point belongs to one of the given pids. No script calls it; it is for manual use.
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count > 4 else { print("usage: scroll <x> <y> <lines> <pid>..."); exit(2) }
let p = CGPoint(x: Double(a[1])!, y: Double(a[2])!); let n = Int32(a[3])!; let pids = Set(a.dropFirst(4).compactMap { Int($0) })
func topOwner(at p: CGPoint) -> (Int, String)? {
    for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        guard owner != "Window Server", (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
              let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
        return (w[kCGWindowOwnerPID as String] as? Int ?? -1, owner)
    }
    return nil
}
guard let (owner, name) = topOwner(at: p), pids.contains(owner) else { print("scroll: refusing: the topmost window at \(p) is not one of pids \(pids.sorted())"); exit(1) }
_ = name
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(100000)
for _ in 0..<abs(n) { CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: n < 0 ? -5 : 5, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap); usleep(30000) }
