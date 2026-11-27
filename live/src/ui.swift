import ApplicationServices
import AppKit
// (The original's type, key, click and rclick subcommands post global keyboard and mouse events; they were removed, no script uses them.)
// ui dump <pid>                 : roles/titles/values/descriptions of every element in the app's windows (depth-first)
// ui menu <pid> <text>          : AXShowMenu on the element whose title/value/description is <text>
// ui press <pid> <title>        : presses the menu item <title> in any open menu of the app (opens submenus by pressing too)
let a = CommandLine.arguments
func g<T>(_ e: AXUIElement, _ k: String) -> T? { var v: CFTypeRef?; AXUIElementCopyAttributeValue(e, k as CFString, &v); return v as? T }
func kids(_ e: AXUIElement) -> [AXUIElement] { g(e, kAXChildrenAttribute) ?? [] }
func label(_ e: AXUIElement) -> String { [g(e, kAXTitleAttribute) as String?, g(e, kAXValueAttribute) as String?, g(e, kAXDescriptionAttribute) as String?].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ") }
func walk(_ e: AXUIElement, _ d: Int, _ f: (AXUIElement, Int) -> Bool) -> Bool { if f(e, d) { return true }; if d > 40 { return false }; for k in kids(e) { if walk(k, d + 1, f) { return true } }; return false }
switch a[1] {
case "dump":
  let app = AXUIElementCreateApplication(pid_t(a[2])!)
  for w in (g(app, kAXWindowsAttribute) as [AXUIElement]? ?? []) { _ = walk(w, 0) { e, d in let r: String = g(e, kAXRoleAttribute) ?? "?"; let l = label(e); if !l.isEmpty || r == "AXImage" { print(String(repeating: " ", count: min(d, 12)) + r + " " + l) }; return false } }
case "menu":
  let app = AXUIElementCreateApplication(pid_t(a[2])!); var hit: AXUIElement?
  for w in (g(app, kAXWindowsAttribute) as [AXUIElement]? ?? []) { if walk(w, 0, { e, _ in if label(e).split(separator: "|").map({ $0.trimmingCharacters(in: .whitespaces) }).contains(a[3]) { hit = e; return true }; return false }) { break } }
  guard var e = hit else { print("no element"); exit(1) }
  // the row may be the parent that has the menu
  for _ in 0..<4 { if AXUIElementPerformAction(e, "AXShowMenu" as CFString) == .success { print("menu shown"); exit(0) }; guard let p: AXUIElement = g(e, kAXParentAttribute) else { break }; e = p }
  print("no menu"); exit(1)
case "press":
  let app = AXUIElementCreateApplication(pid_t(a[2])!); var hit: AXUIElement?
  let roots: [AXUIElement] = (g(app, kAXChildrenAttribute) as [AXUIElement]? ?? [])
  for r in roots { if walk(r, 0, { e, _ in let role: String = g(e, kAXRoleAttribute) ?? ""; if role == "AXMenuItem", (g(e, kAXTitleAttribute) as String?) == a[3] { hit = e; return true }; return false }) { break } }
  guard let e = hit else { print("no item"); exit(1) }
  print(AXUIElementPerformAction(e, kAXPressAction as CFString) == .success ? "pressed" : "failed")
default: print("?")
}
