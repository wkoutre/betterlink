// usage: nd <pid> <name-prefix> <AXIncrement|AXDecrement> <count> [gapMs=30]: presses one element's action several times in a row
import AppKit
import ApplicationServices
let a = CommandLine.arguments; let pid = pid_t(a[1])!
func g(_ e: AXUIElement, _ k: String) -> AnyObject? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v as AnyObject? : nil }
func nm(_ e: AXUIElement) -> String { [g(e, "AXDescription"), g(e, "AXTitle")].compactMap { $0 as? String }.joined(separator: "|") }
let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 5)
var hit: AXUIElement?
func walk(_ e: AXUIElement, _ d: Int) { if hit != nil { return }; if nm(e).hasPrefix(a[2]) { hit = e; return }; if d < 14 { for c in g(e, "AXChildren") as? [AXUIElement] ?? [] { walk(c, d + 1) } } }
for w in g(app, "AXWindows") as? [AXUIElement] ?? [] where g(w, "AXRole") as? String == "AXWindow" { walk(w, 0) }
guard let e = hit else { print("no element"); exit(1) }
let n = Int(a[4])!, gap = a.count > 5 ? UInt32(a[5])! : 30
let t0 = Date()
var codes: [Int32] = []
for i in 0..<n { codes.append(AXUIElementPerformAction(e, a[3] as CFString).rawValue); if i < n - 1 { usleep(gap * 1000) } }
print("pressed \(n)x in \(Int(Date().timeIntervalSince(t0) * 1000)) ms, results \(codes), value \(g(e, "AXValue") as? String ?? "")")
