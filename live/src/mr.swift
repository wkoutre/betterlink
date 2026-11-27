// mr <seconds> <pid>...: CPU, wakeups and memory of each pid over <seconds>.
// Reads proc_pid_rusage (RUSAGE_INFO_V4) at the start and at the end and prints one line per pid:
//   <pid>: cpu X.XX%  wakeups Y.Y/s  memory Z.Z MB
// cpu = (user + system time delta) / wall time; wakeups = (ri_pkg_idle_wkups + ri_interrupt_wkups) delta per second;
// memory = ri_phys_footprint at the end. A pid that cannot be read prints "<pid>: gone".
import Darwin
import Foundation
let a = CommandLine.arguments
guard a.count > 2, let secs = Double(a[1]), secs > 0 else { print("usage: mr <seconds> <pid>..."); exit(2) }
let pids = a.dropFirst(2).compactMap { pid_t($0) }
func read(_ pid: pid_t) -> rusage_info_v4? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return rc == 0 ? info : nil
}
var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
func ns(_ t: UInt64) -> Double { Double(t) * Double(tb.numer) / Double(tb.denom) }
let t0 = Date(); let first = pids.map { read($0) }
Thread.sleep(forTimeInterval: secs)
let wall = Date().timeIntervalSince(t0); let last = pids.map { read($0) }
for (i, pid) in pids.enumerated() {
    guard let x = first[i], let y = last[i] else { print("\(pid): gone"); continue }
    let cpu = (ns(y.ri_user_time - x.ri_user_time) + ns(y.ri_system_time - x.ri_system_time)) / 1e9 / wall * 100
    let wk = Double((y.ri_pkg_idle_wkups - x.ri_pkg_idle_wkups) + (y.ri_interrupt_wkups - x.ri_interrupt_wkups)) / wall
    print(String(format: "%d: cpu %.2f%%  wakeups %.1f/s  memory %.1f MB", pid, cpu, wk, Double(y.ri_phys_footprint) / 1_048_576))
}
