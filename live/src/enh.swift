// enh <pid> [on|off]: reads or sets AXEnhancedUserInterface on an app
import ApplicationServices
let a = CommandLine.arguments; let app = AXUIElementCreateApplication(pid_t(a[1])!)
if a.count > 2 { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, (a[2] == "on" ? kCFBooleanTrue : kCFBooleanFalse)!) }
var v: CFTypeRef?; let e = AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &v); print(e == .success ? "\(v!)" : "err \(e.rawValue)")
