// betterlink macOS 27 window-animation probe.
//
// Run:   swift probe.swift --read     (only lists each app's AXEnhancedUserInterface; moves nothing)
//        swift probe.swift            (uses a new TextEdit window it opens and closes)
//        swift probe.swift --pid N    (uses the front window of app N instead, e.g. a throwaway browser window you just opened)
// Needs: the app you run it from (Terminal, Ghostty...) allowed under Privacy & Security > Accessibility.
// It moves and resizes only that one window, puts it back where it was, restores the app's
// AXEnhancedUserInterface setting, and (TextEdit) closes only the untitled document it made, matched by
// name and text, without saving. With --pid it touches only that app's front window and closes nothing.
// Output: a summary on screen and every sampled frame in /tmp/betterlink-probe27.csv (or the file named by BETTERLINK_PROBE_CSV).
import AppKit
import ApplicationServices
import Foundation

typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
let getWindow = unsafeBitCast(dlsym(dlopen(nil, RTLD_NOW), "_AXUIElementGetWindow"), to: GetWindow.self)

func die(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }
guard AXIsProcessTrusted() else { die("Allow this terminal app under System Settings > Privacy & Security > Accessibility, then run again.") }

// --read: only prints AXEnhancedUserInterface for every running app that has windows; moves nothing.
if CommandLine.arguments.contains("--read") {
    for r in NSWorkspace.shared.runningApplications where r.activationPolicy == .regular {
        var v: CFTypeRef?; let e = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(r.processIdentifier), "AXEnhancedUserInterface" as CFString, &v)
        print("\(r.bundleIdentifier ?? "?") pid \(r.processIdentifier): AXEnhancedUserInterface \(e == .success ? String(describing: v!) : "not set (\(e.rawValue))")")
    }
    exit(0)
}
var pid: pid_t = 0
var openedTextEdit = false
var probeDoc = ""
if let i = CommandLine.arguments.firstIndex(of: "--pid"), i + 1 < CommandLine.arguments.count { pid = pid_t(CommandLine.arguments[i + 1])! } else {
    let s = "tell application \"TextEdit\"\nactivate\nset d to make new document with properties {text:\"betterlink probe, closes itself\"}\nreturn name of d\nend tell"
    var err: NSDictionary?; let r = NSAppleScript(source: s)!.executeAndReturnError(&err)
    if let err { die("TextEdit: \(err)") }
    probeDoc = r.stringValue ?? ""
    openedTextEdit = true; Thread.sleep(forTimeInterval: 1.5)
    pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first!.processIdentifier
}
let app = AXUIElementCreateApplication(pid)
func attr<T>(_ e: AXUIElement, _ a: String) -> T? { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? T : nil }
var win: AXUIElement = { if let w: AXUIElement = attr(app, kAXFocusedWindowAttribute) { return w }; let ws: [AXUIElement] = attr(app, kAXWindowsAttribute) ?? []; guard let w = ws.first else { die("no window for pid \(pid)") }; return w }()
var wid: CGWindowID = 0; _ = getWindow(win, &wid)
guard wid != 0 else { die("could not read the window number") }

func serverFrame() -> CGRect? {
    let l = CGWindowListCopyWindowInfo([.optionIncludingWindow], wid) as? [[String: Any]] ?? []
    guard let b = l.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
    return CGRect(dictionaryRepresentation: b)
}
func setSize(_ s: CGSize) { var s = s; AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &s)!) }
func setPos(_ p: CGPoint) { var p = p; AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!) }
let enhanced = "AXEnhancedUserInterface" as CFString
var enhancedBefore: CFTypeRef?; AXUIElementCopyAttributeValue(app, enhanced, &enhancedBefore)
func setEnhanced(_ on: Bool) { AXUIElementSetAttributeValue(app, enhanced, (on ? kCFBooleanTrue : kCFBooleanFalse)!) }

func settle(_ max: Double = 3) { var last = serverFrame(); var still = Date(); let t0 = Date()
    while Date().timeIntervalSince(t0) < max { usleep(10_000); let f = serverFrame(); if f != last { last = f; still = Date() } else if Date().timeIntervalSince(still) > 0.4 { return } } }

guard let f0 = serverFrame() else { die("no frame") }
func putBack() { setPos(f0.origin); setSize(f0.size); settle(); setPos(f0.origin); setSize(f0.size); settle() }
let d: CGFloat = 280
let target = CGRect(x: f0.minX + d, y: f0.minY, width: f0.width - d, height: f0.height)
var csv = "case,ms,x,y,w,h,right\n"

// Runs `act` at t=0 and samples the window server's frame every ~4 ms for `ms`.
func run(_ name: String, ms: Double = 900, _ act: @escaping () -> Void) {
    putBack()
    var samples: [(Double, CGRect)] = []
    let t0 = Date()
    let q = DispatchQueue(label: "act"); q.async(execute: act)
    while true { let t = Date().timeIntervalSince(t0) * 1000; if t > ms { break }
        if let f = serverFrame(), samples.last?.1 != f { samples.append((t, f)) }; usleep(4000) }
    q.sync {}
    for (t, f) in samples { csv += String(format: "%@,%.1f,%.0f,%.0f,%.0f,%.0f,%.0f\n", name, t, f.minX, f.minY, f.width, f.height, f.maxX) }
    let far = f0.maxX
    let moved = samples.filter { $0.1 != f0 }
    let maxFar = samples.map { abs($0.1.maxX - far) }.max() ?? 0
    let last = samples.last?.1 ?? f0
    let firstT = moved.first.map { String(format: "%.0f", $0.0) } ?? "-"
    let doneT = samples.last.map { String(format: "%.0f", $0.0) } ?? "-"
    print(String(format: "%-34@ frames %3d  first change %5@ ms  last change %5@ ms  far edge moved up to %4.0f pt  ended %.0f,%.0f %.0fx%.0f%@", name as NSString, moved.count, firstT as NSString, doneT as NSString, maxFar, last.minX, last.minY, last.width, last.height, (last == target ? "  (= target)" : "") as NSString))
}

print("window \(wid) of pid \(pid) at \(f0); target \(target); AXEnhancedUserInterface was \(String(describing: enhancedBefore))")
var settable: DarwinBoolean = false
AXUIElementIsAttributeSettable(win, "AXFrame" as CFString, &settable)
var names: CFArray?; AXUIElementCopyAttributeNames(win, &names)
print("AXFrame settable: \(settable.boolValue); window attributes: \((names as? [String] ?? []).joined(separator: " "))")

for on in [true, false] {
    setEnhanced(on); let tag = on ? "UI on " : "UI off"
    run("\(tag) size only") { setSize(target.size) }
    run("\(tag) position only") { setPos(target.origin) }
    run("\(tag) size then position") { setSize(target.size); setPos(target.origin) }
    run("\(tag) position then size") { setPos(target.origin); setSize(target.size) }
    if settable.boolValue { run("\(tag) AXFrame") { var r = target; AXUIElementSetAttributeValue(win, "AXFrame" as CFString, AXValueCreate(.cgRect, &r)!) } }
    run("\(tag) 18-step slide at 60 fps", ms: 1200) {
        for i in 1...18 { let k = CGFloat(i) / 18; let w = f0.width - d * k
            setSize(CGSize(width: w, height: f0.height)); setPos(CGPoint(x: f0.maxX - w, y: f0.minY)); usleep(16_667) } }
}

// Put everything back.
if let e = enhancedBefore { AXUIElementSetAttributeValue(app, enhanced, e) } else { setEnhanced(false) }
putBack()
let csvPath = ProcessInfo.processInfo.environment["BETTERLINK_PROBE_CSV"] ?? "/tmp/betterlink-probe27.csv"
try? csv.write(toFile: csvPath, atomically: true, encoding: .utf8)
// Closes only the probe's own document: matched by its name and its text, never another one.
if openedTextEdit, !probeDoc.isEmpty { var err: NSDictionary?; NSAppleScript(source: "tell application \"TextEdit\" to close (every document whose name is \"\(probeDoc)\" and text is \"betterlink probe, closes itself\") saving no")!.executeAndReturnError(&err) }
print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString); samples in \(csvPath)")
