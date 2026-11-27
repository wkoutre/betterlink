import ApplicationServices
let app=AXUIElementCreateApplication(pid_t(CommandLine.arguments[1])!);var v:CFTypeRef?;AXUIElementCopyAttributeValue(app,"AXWindows" as CFString,&v)
for w in v as! [AXUIElement]{var b:CFTypeRef?;if AXUIElementCopyAttributeValue(w,"AXCloseButton" as CFString,&b) == .success{print(AXUIElementPerformAction(b as! AXUIElement,"AXPress" as CFString).rawValue)}}
