import Foundation
import Testing
@testable import Betterlink

/// The browser's enhanced user interface held off for a motion and set back
/// (`EnhancedUI`), and its record for a betterlink that stops mid-motion.
@MainActor @Suite(.serialized) struct EnhancedUITests {
    private let pid: pid_t = 60_001

    private func make() -> (EnhancedUI, FakeApps, URL) {
        let journal = FileManager.default.temporaryDirectory.appendingPathComponent("enhanced-ui-\(UUID().uuidString).json")
        let apps = FakeApps()
        return (EnhancedUI(app: apps, journal: journal), apps, journal)
    }

    @Test func onIsSetOffRecordedAndSetBack() {
        let (ui, apps, journal) = make()
        apps.flags[pid] = true
        let owner = NSObject()
        #expect(ui.hold(pid, by: owner) == .init(off: true, missed: false))
        #expect(apps.flags[pid] == false)
        // Written down before it was set off: one entry, with when the process started.
        #expect(ui.read() == [.init(pid: pid, launched: 1_000_000, was: true)])
        ui.release(pid, by: owner)
        #expect(apps.flags[pid] == true)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
        #expect(apps.calls.map(\.set) == [nil, false, true])
    }

    @Test func offIsReadNeverSet() {
        let (ui, apps, _) = make()
        apps.flags[pid] = false
        let owner = NSObject()
        #expect(ui.hold(pid, by: owner) == .init(off: true, missed: false))
        ui.release(pid, by: owner)
        #expect(apps.calls.map(\.set) == [nil])
        #expect(ui.read().isEmpty)
    }

    /// Two windows of one browser moving at once: one flip, set back when the last is done.
    @Test func windowsOfOneBrowserShareOneHold() {
        let (ui, apps, _) = make()
        apps.flags[pid] = true
        let a = NSObject(), b = NSObject()
        ui.hold(pid, by: a)
        ui.hold(pid, by: b)
        ui.release(pid, by: a)
        #expect(apps.flags[pid] == false && ui.isHeld(pid))
        ui.release(pid, by: a) // released twice: nothing more
        #expect(apps.flags[pid] == false)
        ui.release(pid, by: b)
        #expect(apps.flags[pid] == true && !ui.isHeld(pid))
        #expect(apps.calls.map(\.set) == [nil, false, true])
    }

    /// A flag that can't be set off: sets stay animated (`off` false), and nothing is set back or kept.
    @Test func aFlagThatCantBeSetOff() {
        let (ui, apps, _) = make()
        apps.flags[pid] = true
        apps.stuck = [pid]
        let owner = NSObject()
        #expect(ui.hold(pid, by: owner) == .init(off: false, missed: false))
        ui.release(pid, by: owner)
        #expect(apps.flags[pid] == true && apps.calls.map(\.set) == [nil, false])
        #expect(ui.read().isEmpty)
    }

    /// A process that can't be told from a later one (no start time) is never set off.
    @Test func noRecordNoFlip() {
        let (ui, apps, _) = make()
        apps.flags[pid] = true
        ui.journal = URL(fileURLWithPath: "/dev/null/enhanced-ui.json") // can't be written
        let owner = NSObject()
        #expect(ui.hold(pid, by: owner).off == false)
        ui.release(pid, by: owner)
        #expect(apps.flags[pid] == true && apps.calls.map(\.set) == [nil])
    }

    /// betterlink stopped mid-motion (a crash): the next launch sets the flag
    /// back for the same process (same pid, same start), and leaves a pid
    /// since given to another process, or no longer running, alone.
    @Test func theNextLaunchSetsBackWhatACrashLeftOff() {
        let (ui, apps, journal) = make()
        apps.flags = [pid: true, pid + 1: true, pid + 2: true]
        for p in [pid, pid + 1, pid + 2] { ui.hold(p, by: NSObject()) }
        #expect(apps.flags.values.allSatisfy { !$0 } && ui.read().count == 3)
        // The crash: nothing set back. The next launch, with pid + 1 now another process and pid + 2 gone.
        let later = EnhancedUI(app: apps, journal: journal)
        apps.launches[pid + 1] = Date(timeIntervalSince1970: 2_000_000)
        let gone = FakeAppsGone(apps, gone: pid + 2)
        later.app = gone
        later.recover()
        #expect(apps.flags[pid] == true)
        #expect(apps.flags[pid + 1] == false, "another process's flag set")
        #expect(apps.flags[pid + 2] == false)
        #expect(later.read().isEmpty && !FileManager.default.fileExists(atPath: journal.path))
    }
}

/// `FakeApps` with one pid no longer running.
@MainActor
private final class FakeAppsGone: EnhancedUIApp {
    let apps: FakeApps, gone: pid_t
    init(_ apps: FakeApps, gone: pid_t) { self.apps = apps; self.gone = gone }
    var missed: Bool { apps.missed }
    func read(_ pid: pid_t, wait: Double) -> Bool? { apps.read(pid, wait: wait) }
    func set(_ pid: pid_t, _ on: Bool, wait: Double) -> Bool { apps.set(pid, on, wait: wait) }
    func launched(_ pid: pid_t) -> Date? { pid == gone ? nil : apps.launched(pid) }
}
