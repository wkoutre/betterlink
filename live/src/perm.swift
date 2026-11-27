// perm: prints "accessibility=true|false screenrecording=true|false" for the app this runs from (the terminal).
// It only asks macOS whether the permission is held; it never shows a prompt (AXIsProcessTrusted and
// CGPreflightScreenCaptureAccess do not prompt). Exit 0 when both are held, 1 otherwise.
import ApplicationServices
import CoreGraphics
let ax = AXIsProcessTrusted(), sr = CGPreflightScreenCaptureAccess()
print("accessibility=\(ax) screenrecording=\(sr)")
exit(ax && sr ? 0 : 1)
