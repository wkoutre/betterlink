import ApplicationServices
let a=CommandLine.arguments;let app=AXUIElementCreateApplication(pid_t(a[1])!);var v:CFTypeRef?;AXUIElementCopyAttributeValue(app,"AXWindows" as CFString,&v)
let w=(v as! [AXUIElement]).first{var r:CFTypeRef?;AXUIElementCopyAttributeValue($0,"AXRole" as CFString,&r);return r as? String=="AXWindow"}!;var p=CGPoint(x:Double(a[2])!,y:Double(a[3])!),s=CGSize(width:Double(a[4])!,height:Double(a[5])!)
for _ in 0..<2{AXUIElementSetAttributeValue(w,"AXPosition" as CFString,AXValueCreate(.cgPoint,&p)!);AXUIElementSetAttributeValue(w,"AXSize" as CFString,AXValueCreate(.cgSize,&s)!)}
