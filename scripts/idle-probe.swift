// What check-idle.sh needs to know before it measures a sidebar:
//   swiftc -O scripts/idle-probe.swift -o .build/idle-probe
//   .build/idle-probe <pid>
// Prints "trusted yes|no": whether a process started from this shell may use
// Accessibility (the sidebar does nothing without it). And "windows <n>": how
// many windows process <pid> has on screen at the normal or the floating
// level, which is the app's own window plus one for each sidebar beside a
// browser window (a sidebar floats while another app is in front). The toast,
// at the status level, is not counted. Window owners and levels need no
// Screen Recording permission.
import ApplicationServices
import CoreGraphics
import Foundation

guard let arg = CommandLine.arguments.dropFirst().first, let pid = Int(arg) else {
    print("usage: idle-probe <pid>"); exit(2)
}
print("trusted \(AXIsProcessTrusted() ? "yes" : "no")")
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let levels = [Int(CGWindowLevelForKey(.normalWindow)), Int(CGWindowLevelForKey(.floatingWindow))]
let mine = list.filter {
    ($0[kCGWindowOwnerPID as String] as? Int) == pid && levels.contains($0[kCGWindowLayer as String] as? Int ?? -1)
}
print("windows \(mine.count)")
