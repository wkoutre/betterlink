import ApplicationServices
import AppKit
// wn <pid> list | set <title-part> x y w h | raise <title-part> | min <title-part> 0|1 | full <title-part> 0|1 | close <title-part>
let a = CommandLine.arguments; let pid = pid_t(a[1])!; let app = AXUIElementCreateApplication(pid)
func g<T>(_ e: AXUIElement, _ k: String) -> T? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v as? T }
func frame(_ e: AXUIElement) -> String {
    guard let p: AXValue = g(e, "AXPosition"), let s: AXValue = g(e, "AXSize") else { return "?" }
    var o = CGPoint.zero, z = CGSize.zero; AXValueGetValue(p, .cgPoint, &o); AXValueGetValue(s, .cgSize, &z); return "\(Int(o.x)) \(Int(o.y)) \(Int(z.width)) \(Int(z.height))"
}
let wins = ((g(app, "AXWindows") as [AXUIElement]?) ?? []).filter { (g($0, "AXRole") as String?) == "AXWindow" }
func find(_ part: String) -> AXUIElement? { wins.first { ((g($0, "AXTitle") as String?) ?? "").contains(part) } }
switch a[2] {
case "list": for w in wins { print("\((g(w, "AXTitle") as String?) ?? "") | \(frame(w)) | min=\((g(w, "AXMinimized") as Bool?) ?? false) full=\((g(w, "AXFullScreen") as Bool?) ?? false) main=\((g(w, "AXMain") as Bool?) ?? false)") }
case "set": if let w = find(a[3]) { var p = CGPoint(x: Double(a[4])!, y: Double(a[5])!), s = CGSize(width: Double(a[6])!, height: Double(a[7])!)
    for _ in 0..<2 { AXUIElementSetAttributeValue(w, "AXPosition" as CFString, AXValueCreate(.cgPoint, &p)!); AXUIElementSetAttributeValue(w, "AXSize" as CFString, AXValueCreate(.cgSize, &s)!) } } else { print("no window") }
case "raise": if let w = find(a[3]) { NSRunningApplication(processIdentifier: pid)?.activate(options: []); usleep(150000); print(AXUIElementPerformAction(w, "AXRaise" as CFString).rawValue); AXUIElementSetAttributeValue(w, "AXMain" as CFString, kCFBooleanTrue) } else { print("no window") }
case "min": if let w = find(a[3]) { AXUIElementSetAttributeValue(w, "AXMinimized" as CFString, (a[4] == "1") as CFBoolean) } else { print("no window") }
case "full": if let w = find(a[3]) { AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, (a[4] == "1") as CFBoolean) } else { print("no window") }
case "close": if let w = find(a[3]), let b: AXUIElement = g(w, "AXCloseButton") { print(AXUIElementPerformAction(b, "AXPress" as CFString).rawValue) } else { print("no window") }
default: break
}
