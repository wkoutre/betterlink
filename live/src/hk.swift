// hk <pid>: sends betterlink's default sidebar shortcut (control+option+S, key code 1) to the frontmost app, but only when the frontmost app is <pid>
// (the throwaway browser). Refuses (exit 1) otherwise, so the keystroke never reaches anything else.
import AppKit
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count > 1, let want = Int32(a[1]) else { print("usage: hk <pid of the throwaway browser>"); exit(2) }
let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
guard front == want else { print("hk: refusing to send the shortcut: the frontmost app is pid \(front), not \(want)"); exit(1) }
for d in [true,false]{let e=CGEvent(keyboardEventSource:nil,virtualKey:1,keyDown:d)!;e.flags=[.maskControl,.maskAlternate];e.post(tap:.cghidEventTap);usleep(40000)}
