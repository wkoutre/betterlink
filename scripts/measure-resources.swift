// What a process costs over a while, from the kernel's own counters:
//   swiftc -O scripts/measure-resources.swift -o .build/measure-resources
//   .build/measure-resources [--max-cpu <%>] [--max-wakeups <per second>] <seconds> <pid> [<pid> ...]
// Prints CPU (% of one core), wakeups per second and memory for each pid, and
// fails when one is over a maximum or gone.
// docs/resources.md has the scenarios and the budgets.
import Darwin
import Foundation

func usage(_ pid: pid_t) -> rusage_info_v4? {
    var r = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &r) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? r : nil
}

// The times are in Mach units.
var base = mach_timebase_info_data_t()
mach_timebase_info(&base)
func seconds(_ t: UInt64) -> Double { Double(t) * Double(base.numer) / Double(base.denom) / 1e9 }

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> Double? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard args.indices.contains(i + 1), let v = Double(args[i + 1]) else { print("\(name) needs a number"); exit(2) }
    args.removeSubrange(i...(i + 1))
    return v
}
let maxCPU = option("--max-cpu"), maxWakeups = option("--max-wakeups")
var failed = false
guard let first = args.first, let span = Double(first), args.count > 1 else {
    print("usage: measure-resources [--max-cpu <%>] [--max-wakeups <per second>] <seconds> <pid> [<pid> ...]"); exit(2)
}
let pids = args.dropFirst().map { a -> pid_t in
    guard let p = pid_t(a) else { print("\(a) is not a pid"); exit(2) }
    return p
}
let before = pids.map(usage), start = Date()
Thread.sleep(forTimeInterval: span)
let took = Date().timeIntervalSince(start)
for (pid, b) in zip(pids, before) {
    guard let b, let a = usage(pid) else { print("\(pid): gone"); failed = true; continue }
    let cpu = seconds(a.ri_user_time + a.ri_system_time) - seconds(b.ri_user_time + b.ri_system_time)
    let wakes = Double(a.ri_interrupt_wkups - b.ri_interrupt_wkups) + Double(a.ri_pkg_idle_wkups - b.ri_pkg_idle_wkups)
    print(String(format: "%d: cpu %.2f%%  wakeups %.1f/s  memory %.1f MB", pid, cpu / took * 100, wakes / took,
                 Double(a.ri_phys_footprint) / 1_048_576))
    if let maxCPU, cpu / took * 100 > maxCPU { print("\(pid): over \(maxCPU)% CPU"); failed = true }
    if let maxWakeups, wakes / took > maxWakeups { print("\(pid): over \(maxWakeups) wakeups/s"); failed = true }
}
exit(failed ? 1 : 0)
