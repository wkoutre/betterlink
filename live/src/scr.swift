import AppKit
let s=NSScreen.screens;for x in s{print(Int(x.visibleFrame.minX),Int(s[0].frame.height-x.visibleFrame.maxY),Int(x.visibleFrame.width),Int(x.visibleFrame.height),x.backingScaleFactor)}
