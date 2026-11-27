// usage: edr <appPid> <browserPid> <left|right> <dx> [ms=1500] [steps=60]
// Drags the sidebar's inner edge by dx points and samples, after every step,
// where the pointer, the panel's inner edge and the browser's near edge are.
// Safety: it presses the mouse only when the topmost window under the start point belongs to <appPid> or <browserPid>.
import CoreGraphics
import Foundation
let a = CommandLine.arguments
let app = Int(a[1])!, br = Int(a[2])!, side = a[3], dx = Double(a[4])!
let ms = a.count > 5 ? Double(a[5])! : 1500, steps = a.count > 6 ? Int(a[6])! : 60
func rects(_ pid: Int) -> [CGRect] {
    (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]])
        .filter { $0["kCGWindowOwnerPID"] as? Int == pid && ($0["kCGWindowLayer"] as? Int ?? 9) < 25 }
        .compactMap { CGRect(dictionaryRepresentation: $0["kCGWindowBounds"] as! CFDictionary) }
}
func browser() -> CGRect { rects(br).max { $0.width * $0.height < $1.width * $1.height } ?? .zero }
func panel(_ b: CGRect) -> CGRect {
    rects(app).filter { abs($0.height - b.height) < 60 && $0.width > 150 && $0.width < 520 && abs($0.midY - b.midY) < 60 }
        .min { abs(($0.midX) - (side == "left" ? b.minX : b.maxX)) < abs(($1.midX) - (side == "left" ? b.minX : b.maxX)) } ?? .zero
}
func post(_ t: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
func inner(_ p: CGRect) -> Double { side == "left" ? p.maxX : p.minX }
func near(_ b: CGRect) -> Double { side == "left" ? b.minX : b.maxX }
/// The owner of the topmost window under a point (front to back), ignoring the window server's own layers.
func topOwner(at p: CGPoint) -> (Int, String)? {
    for w in CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [] {
        let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
        guard owner != "Window Server", (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
              let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b), r.contains(p) else { continue }
        return (w[kCGWindowOwnerPID as String] as? Int ?? -1, owner)
    }
    return nil
}
let b0 = browser(), p0 = panel(b0)
guard p0 != .zero else { print("no panel beside the browser", b0, rects(app)); exit(1) }
let off = side == "left" ? -3.0 : 3.0
let start = CGPoint(x: near(b0) + off, y: p0.midY)   // the handle is the sidebar's last 8 pt before the window's edge
let reach0 = inner(p0) - near(b0)
guard let top = topOwner(at: start), top.0 == app || top.0 == br else { print("edr: refusing to press the mouse at \(start): the topmost window there is \(topOwner(at: start).map { "\($0.1) pid \($0.0)" } ?? "none"), not pid \(app) or \(br)"); exit(2) }
print("start browser \(b0) panel \(p0) seam \(near(b0)) panel over the window by \(abs(reach0))")
post(.mouseMoved, start); usleep(120_000); post(.leftMouseDown, start); usleep(150_000)
var maxTrail = 0.0, maxGap = 0.0, rows: [String] = []
func sample(_ px: Double, _ tag: String) {
    let b = browser(), p = panel(b)
    let trail = (px - off) - near(b)                  // + : pointer is right of the window's edge
    let gap = (inner(p) - near(b)) - reach0           // the panel's edge against the window's edge, 0 = together
    maxTrail = max(maxTrail, abs(trail)); maxGap = max(maxGap, abs(gap))
    rows.append(String(format: "%@ ptr %.0f window edge %.1f trail %+.1f panel-off-edge %+.1f  w(panel) %.0f w(browser) %.0f", tag, px, near(b), trail, gap, p.width, b.width))
}
for i in 1...steps {
    let x = start.x + dx * Double(i) / Double(steps)
    post(.leftMouseDragged, CGPoint(x: x, y: start.y)); usleep(UInt32(ms * 1000 / Double(steps)))
    sample(x, String(format: "%3d", i))
}
let end = start.x + dx
let dragTrail = maxTrail
usleep(400_000); sample(end, "held"); let heldEnd = abs((end - off) - near(browser()))
post(.leftMouseUp, CGPoint(x: end, y: start.y)); usleep(700_000); sample(end, " up ")
for (i, r) in rows.enumerated() where i % 6 == 5 || i >= rows.count - 2 { print(r) }
let b1 = browser(), p1 = panel(b1)
print(String(format: "SUMMARY side %@ dx %+.0f over %.0f ms: while dragging the window's edge was at most %.1f pt from the pointer (%.1f once held 0.4 s), the panel at most %.1f pt off the window's edge; far edge moved %.1f; pair width %.1f -> %.1f; panel %.0f -> %.0f",
    side, dx, ms, dragTrail, heldEnd, maxGap,
    side == "left" ? b1.maxX - b0.maxX : b1.minX - b0.minX, b0.width + p0.width, b1.width + p1.width, p0.width, p1.width))
