import CoreGraphics
import Foundation
let pid=Int(CommandLine.arguments[1])!
for i in CGWindowListCopyWindowInfo([.optionAll],kCGNullWindowID) as! [[String:Any]] where i["kCGWindowOwnerPID"] as? Int==pid { print(i["kCGWindowNumber"]!, i["kCGWindowBounds"]!, i["kCGWindowLayer"]!) }
