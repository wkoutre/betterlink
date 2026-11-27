// ax <pid> tree|frames|do <name-prefix> <action>|front: reads or acts on ONE app's windows through Accessibility (the app given by pid).
// The original's click, drag, key and type subcommands (global mouse and keyboard events) were removed: no script uses them.
import AppKit
import ApplicationServices
let a=CommandLine.arguments; let pid=pid_t(a[1])!
func g(_ e:AXUIElement,_ k:String)->AnyObject?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,k as CFString,&v) == .success ? v as AnyObject? : nil}
func fr(_ e:AXUIElement)->CGRect{var p=CGPoint.zero,s=CGSize.zero;if let v=g(e,"AXPosition"){AXValueGetValue(v as! AXValue,.cgPoint,&p)};if let v=g(e,"AXSize"){AXValueGetValue(v as! AXValue,.cgSize,&s)};return CGRect(origin:p,size:s)}
func kids(_ e:AXUIElement)->[AXUIElement]{g(e,"AXChildren") as? [AXUIElement] ?? []}
func nm(_ e:AXUIElement)->String{[g(e,"AXDescription"),g(e,"AXTitle"),g(e,"AXValue"),g(e,"AXPlaceholderValue")].compactMap{$0 as? String}.filter{!$0.isEmpty}.joined(separator:"|")}
let app=AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,5)
func walk(_ e:AXUIElement,_ d:Int,_ f:(AXUIElement,Int)->Void){f(e,d);if d<14{for c in kids(e){walk(c,d+1,f)}}}
func find(_ n:String)->AXUIElement?{var hit:AXUIElement?;for w in (g(app,"AXWindows") as? [AXUIElement] ?? []) where g(w,"AXRole") as? String == "AXWindow"{walk(w,0){e,_ in if hit==nil,nm(e).hasPrefix(n){hit=e}}};return hit}
func acts(_ e:AXUIElement)->[String]{var v:CFArray?;AXUIElementCopyActionNames(e,&v);return v as? [String] ?? []}
switch a[2]{
case "tree": print("trusted",AXIsProcessTrusted()); for w in (g(app,"AXWindows") as? [AXUIElement] ?? []) where g(w,"AXRole") as? String == "AXWindow"{walk(w,0){e,d in let r=fr(e);print(String(repeating:" ",count:d),g(e,"AXRole") as? String ?? "",nm(e).prefix(50),Int(r.minX),Int(r.minY),Int(r.width),Int(r.height))}}
case "frames": for w in (g(app,"AXWindows") as? [AXUIElement] ?? []) where g(w,"AXRole") as? String == "AXWindow"{print(g(w,"AXTitle") as? String ?? "",fr(w))}
case "do": if let e=find(a[3]){print(acts(e),AXUIElementPerformAction(e,a[4] as CFString).rawValue)}else{print("no element")}
case "front": print(NSRunningApplication(processIdentifier:pid)!.activate(options:[.activateAllWindows]))
default:break}
