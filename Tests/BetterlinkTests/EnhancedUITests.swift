import AppKit
import Foundation
import Testing
import BetterlinkCore
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

    /// With VoiceOver or Switch Control on, the flag is theirs: no hold, not
    /// read, not set, nothing recorded; the motion goes as it did before
    /// there was a hold (Nick, F3 of 1df43a3's review). Read anew at each
    /// motion: once it is off, the next hold sets the flag off as built.
    @Test func leftAloneWhileAnAssistiveAppIsOn() {
        for name in ["VoiceOver", "Switch Control"] {
            let (ui, apps, journal) = make()
            apps.flags[pid] = true
            var lines: [String] = []
            DragTrace.echo = { lines.append($0) }
            defer { DragTrace.echo = nil }
            ui.assistive = { name }
            let owner = NSObject()
            #expect(ui.hold(pid, by: owner) == .init(off: false, missed: false), "\(name)")
            #expect(!ui.isHeld(pid))
            ui.release(pid, by: owner)
            #expect(apps.calls.isEmpty, "\(name): \(apps.calls.map(\.set))")
            #expect(apps.flags[pid] == true)
            #expect(!FileManager.default.fileExists(atPath: journal.path))
            #expect(lines.contains("enhanced UI: pid \(pid) left alone, \(name) on"), "\(lines)")
            // Turned off: the next motion holds the flag off and sets it back.
            ui.assistive = { nil }
            #expect(ui.hold(pid, by: owner).off)
            #expect(apps.flags[pid] == false)
            ui.release(pid, by: owner)
            #expect(apps.flags[pid] == true)
        }
    }

    /// The app's own reading: VoiceOver's and Switch Control's state from
    /// NSWorkspace, nothing else (the default seam).
    @Test func theSystemReadingIsVoiceOverAndSwitchControl() {
        let reading = EnhancedUI.systemAssistive()
        let ws = NSWorkspace.shared
        #expect(reading == (ws.isVoiceOverEnabled ? "VoiceOver" : ws.isSwitchControlEnabled ? "Switch Control" : nil))
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
        // Read, set off, read back; set back, read back.
        #expect(apps.calls.map(\.set) == [nil, false, nil, true, nil])
    }

    /// Chromium on macOS 27 answers every set of the flag with -25208
    /// (kAXErrorNotImplemented) and takes it (the FakeApps default): read
    /// back, it is off, and it is set back. Live at e771f92 this was taken
    /// as refused, and the flag was left off for good.
    @Test func aSetThatErrorsButTakesIsSetBack() {
        let (ui, apps, _) = make()
        apps.flags[pid] = true
        let owner = NSObject()
        #expect(ui.hold(pid, by: owner).off)
        #expect(apps.lastAnswer == -25208 && apps.flags[pid] == false)
        ui.release(pid, by: owner)
        #expect(apps.flags[pid] == true)
        #expect(ui.read().isEmpty)
    }

    /// A set answered with success that doesn't take: read back, it is still
    /// on, so the motion's sets stay animated and nothing is set back.
    @Test func aSetThatSucceedsButDoesntTake() {
        let (ui, apps, _) = make()
        apps.flags[pid] = true
        apps.ignores = [pid]
        let owner = NSObject()
        #expect(ui.hold(pid, by: owner) == .init(off: false, missed: false))
        ui.release(pid, by: owner)
        #expect(apps.flags[pid] == true && apps.calls.map(\.set) == [nil, false, nil])
        #expect(ui.read().isEmpty)
    }

    /// Setting it back doesn't take the first time: read back, and set once more.
    @Test func aSetBackThatDoesntTakeIsSentOnceMore() {
        let (ui, apps, _) = make()
        apps.flags[pid] = true
        let owner = NSObject()
        ui.hold(pid, by: owner)
        apps.ignores = [pid]
        ui.release(pid, by: owner)
        #expect(apps.calls.map(\.set) == [nil, false, nil, true, nil, true, nil])
        #expect(apps.flags[pid] == false)
        // Still recorded, and owed: the next hold sets it back after its motion.
        #expect(ui.read().count == 1)
        apps.ignores = []
        ui.hold(pid, by: owner)
        ui.release(pid, by: owner)
        #expect(apps.flags[pid] == true && ui.read().isEmpty)
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
        #expect(apps.calls.map(\.set) == [nil, false, nil, true, nil])
    }

    /// A flag that can't be set off: sets stay animated (`off` false), and nothing is set back or kept.
    @Test func aFlagThatCantBeSetOff() {
        let (ui, apps, _) = make()
        apps.flags[pid] = true
        apps.stuck = [pid]
        let owner = NSObject()
        #expect(ui.hold(pid, by: owner) == .init(off: false, missed: false))
        ui.release(pid, by: owner)
        #expect(apps.flags[pid] == true && apps.calls.map(\.set) == [nil, false, nil])
        #expect(ui.read().isEmpty)
    }

    /// A browser whose start time can't be had, or a record that can't be
    /// written, is still held off and set back (live at e771f92: a Chrome
    /// for Testing started by a script has no LaunchServices launch date,
    /// and its flag was never set off). Only a crash in between would leave
    /// it off.
    @Test func noRecordStillHolds() {
        for unwritable in [false, true] {
            let (ui, apps, _) = make()
            apps.flags[pid] = true
            if unwritable { ui.journal = URL(fileURLWithPath: "/dev/null/enhanced-ui.json") } else { apps.unstarted = [pid] }
            let owner = NSObject()
            #expect(ui.hold(pid, by: owner).off, "unwritable \(unwritable)")
            #expect(apps.flags[pid] == false)
            ui.release(pid, by: owner)
            #expect(apps.flags[pid] == true && apps.calls.map(\.set) == [nil, false, nil, true, nil], "unwritable \(unwritable)")
        }
    }

    /// The real start time: the kernel's, for any process (this one has no LaunchServices launch date either).
    @Test func theStartTimeComesFromTheKernel() {
        let started = AXEnhancedUIApp().launched(getpid())
        #expect(started.map { $0 < Date() && $0 > Date(timeIntervalSinceNow: -86_400) } == true, "\(String(describing: started))")
        #expect(AXEnhancedUIApp().launched(-1) == nil)
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

    /// The crash record is this Mac's alone: never in the settings folder,
    /// which can be one the person syncs (README, Settings folder), where
    /// another Mac's launch would set back flags by this Mac's pids and the
    /// two would race on the file (review F2 of 1df43a3). With
    /// `BETTERLINK_HOME` (tests, development), under it, so tests stay apart.
    @Test func theCrashRecordIsThisMacsAndNeverInTheSettingsFolder() {
        let synced = URL(fileURLWithPath: "/Users/someone/Dropbox/betterlink", isDirectory: true)
        let defaults = UserDefaults(suiteName: "enhanced-ui-journal-\(UUID().uuidString)")!
        defaults.set(synced.path, forKey: SettingsFolder.defaultsKey)
        let chosen = SettingsFolder.resolve(environment: [:], defaults: defaults).directory
        #expect(chosen.standardizedFileURL == synced.standardizedFileURL)
        let url = EnhancedUI.journalURL(environment: [:])
        #expect(!url.standardizedFileURL.path.hasPrefix(synced.standardizedFileURL.path), "\(url.path)")
        #expect(url.deletingLastPathComponent().standardizedFileURL != SettingsFolder.defaultDirectory.standardizedFileURL, "\(url.path)")
        #expect(url.standardizedFileURL.path.hasPrefix(SettingsFolder.defaultDirectory.standardizedFileURL.path), "\(url.path)")
        #expect(url.lastPathComponent == "enhanced-ui.json")
        // Tests and development: under BETTERLINK_HOME, still never the folder itself.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("bl-home-\(UUID().uuidString)")
        let inHome = EnhancedUI.journalURL(environment: ["BETTERLINK_HOME": home.path])
        #expect(inHome.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path), "\(inHome.path)")
        #expect(inHome.deletingLastPathComponent().standardizedFileURL != home.standardizedFileURL, "\(inHome.path)")
        // The app's own: the shared instance uses this place.
        #expect(EnhancedUI.journalURL().standardizedFileURL == EnhancedUI.journalURL(environment: ProcessInfo.processInfo.environment).standardizedFileURL)
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
    var lastAnswer: Int32 { apps.lastAnswer }

}
