import CoreGraphics
import Foundation
// Front-to-back list of on-screen windows at the normal layer (owner, pid, number, bounds). No titles.
let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
var i = 0
for w in l {
    guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0, let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) > 60 else { continue }
    i += 1
    print("\(i) \(w[kCGWindowOwnerName as String] as? String ?? "?") pid=\(w[kCGWindowOwnerPID as String] as? Int ?? 0) #\(w[kCGWindowNumber as String] as? Int ?? 0) x=\(Int(b["X"]!)) y=\(Int(b["Y"]!)) w=\(Int(b["Width"]!)) h=\(Int(b["Height"]!))")
}
