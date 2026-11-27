// axz <pid> zoom|fs-on|fs-off: presses the front window's zoom button, or sets its AXFullScreen
import ApplicationServices
let a = CommandLine.arguments; let app = AXUIElementCreateApplication(pid_t(a[1])!)
var v: CFTypeRef?; AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &v)
if v == nil { var ws: CFTypeRef?; AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ws); v = (ws as? [AXUIElement])?.first }
guard let w = v else { print("no window"); exit(1) }; let win = w as! AXUIElement
switch a[2] {
case "zoom": var b: CFTypeRef?; AXUIElementCopyAttributeValue(win, kAXZoomButtonAttribute as CFString, &b); print(AXUIElementPerformAction(b as! AXUIElement, kAXPressAction as CFString).rawValue)
default: print(AXUIElementSetAttributeValue(win, "AXFullScreen" as CFString, (a[2] == "fs-on" ? kCFBooleanTrue : kCFBooleanFalse)!).rawValue)
}
