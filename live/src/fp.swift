// fp: prints the pid of the frontmost app (nothing else), so a script can check it before it sends a keystroke.
import AppKit
print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
