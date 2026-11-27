// tm now            : prints the Unix time with milliseconds
// tm until <t0> <s> : sleeps until <t0> + <s> seconds (returns at once if that time has passed)
import Foundation
let a = CommandLine.arguments
if a.count > 1, a[1] == "now" { print(String(format: "%.3f", Date().timeIntervalSince1970)) }
else if a.count > 3, a[1] == "until", let t0 = Double(a[2]), let s = Double(a[3]) {
    let wait = t0 + s - Date().timeIntervalSince1970
    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
} else { print("usage: tm now | tm until <t0> <seconds>"); exit(2) }
