import AppKit
import ApplicationServices
import BetterlinkCore

/// A browser app's `AXEnhancedUserInterface`, as betterlink reads and sets
/// it: in the app, through Accessibility on the app's element; in tests, a
/// fake (SidebarGuardTests).
@MainActor
protocol EnhancedUIApp: AnyObject {
    /// The app's flag now: one Accessibility call. Nil when it has none, or
    /// didn't answer within `wait` seconds (`missed`).
    func read(_ pid: pid_t, wait: Double) -> Bool?
    /// Sets it: one Accessibility call. True when the call succeeded, which
    /// says nothing of whether it took: Chromium on macOS 27 answers every set
    /// with kAXErrorNotImplemented (-25208) and takes it, so whether it took
    /// is always read back.
    func set(_ pid: pid_t, _ on: Bool, wait: Double) -> Bool
    /// The last call got no answer in time: the app is hung or busy.
    var missed: Bool { get }
    /// When the process with this pid started, to tell it from a later
    /// process given the same pid. Nil when none runs.
    func launched(_ pid: pid_t) -> Date?
    /// The last set's answer, for the trace.
    var lastAnswer: Int32 { get }
}

/// Switches a browser's enhanced user interface off while betterlink moves
/// one of its windows, and back to what it was once the move is over.
///
/// With a browser app's `AXEnhancedUserInterface` on (an assistive app sets
/// it, and something on Nick's Mac sets it for Chrome and Brave: read on
/// macOS 27.2.1), macOS animates every size and position set through
/// Accessibility over about 250 ms, and a second set cuts the first short
/// where it has got to. With it off, each set lands at once (measured on
/// macOS 26.5.2 and 27.2.1 with a probe, betterlink-captures/probe27). So:
///
/// - Right before the first set of a show, hide, new width, edge drag or
///   quit, the browser's flag is read (one call, never cached: something
///   may turn it on again between motions). Only when it is on is it set
///   off (one call), written down first (below), and read back (one call):
///   the set's answer says nothing (Chromium on macOS 27 answers every set
///   with -25208, kAXErrorNotImplemented, and takes it; a browser could
///   answer success and not take it). What the read says decides.
/// - Right after the motion's final target has landed (or the motion is
///   capped, taken over by someone else, given up, or the window closes),
///   it is set back to what it was and read back (one call each), once
///   more if it didn't take. Never per frame, never for a motion that moves
///   nothing, never when it was off already. Whenever a flag read on was
///   read off after betterlink's set, it is set back.
/// - Several of the browser's windows moving at once share one hold: the
///   flag goes back once the last of them is done.
/// - Only the browser whose window is being moved is touched.
///
/// Crash safety: before a flag is set off, the browser's pid, the time its
/// process started (the kernel's, `sysctl` KERN_PROC_PID: a browser started
/// by a script or launchd has no LaunchServices launch date) and the value
/// it had are written to `enhanced-ui.json`
/// in betterlink's settings folder (this Mac's, never the sync folder), and
/// removed once it is set back. If betterlink stops in between (a crash, a
/// force quit), the next launch (`recover`) sets the flag back for each
/// recorded browser that is still the same process: the same pid started at
/// the same time. A pid since reused by another process started later, so
/// it is never touched. A browser that doesn't answer when its flag is set
/// back (hung) keeps its entry: the next hold of it sets it back after its
/// motion, and the next launch does if none comes. A flip that can't be
/// written down (no start time, the folder not writable) is made all the
/// same, and the trace says so: the flag is still set back when the motion
/// ends, only a crash in between would leave it off.
@MainActor
final class EnhancedUI {
    static let shared = EnhancedUI(app: AXEnhancedUIApp(),
                                   journal: SettingsFolder.resolve().directory.appendingPathComponent("enhanced-ui.json"))

    var app: EnhancedUIApp
    var journal: URL

    init(app: EnhancedUIApp, journal: URL) {
        self.app = app
        self.journal = journal
    }

    /// What a hold found.
    struct Held: Equatable {
        /// The flag is off now (it was, the app has none, or it was set off):
        /// sets to the app's windows are not animated by it.
        var off: Bool
        /// The app didn't answer in time: it is hung or busy.
        var missed: Bool
    }

    private struct Hold {
        var was: Bool?
        /// Set off by this hold: it is set back when the hold ends.
        var turnedOff: Bool
        var owners: Set<ObjectIdentifier>
        var off: Bool
    }
    private var holds: [pid_t: Hold] = [:]
    /// Set off, and not yet set back because the app didn't answer then.
    private var owed: Set<pid_t> = []

    /// Whether anything holds `pid`'s flag now.
    func isHeld(_ pid: pid_t) -> Bool { holds[pid] != nil }

    /// Whether the hold of `pid` set its flag off (it must be set back).
    func turnedOff(_ pid: pid_t) -> Bool { holds[pid]?.turnedOff == true }

    /// Holds `pid`'s flag off for `owner`'s motion: read, and set off if it
    /// is on. `wait`: how long each call may wait for the app.
    @discardableResult
    func hold(_ pid: pid_t, by owner: AnyObject, wait: Double = AXWindow.callLimit) -> Held {
        if var h = holds[pid] {
            h.owners.insert(ObjectIdentifier(owner))
            holds[pid] = h
            return Held(off: h.off, missed: false)
        }
        let was = timedRead(pid, wait: wait, why: "read")
        let missed = app.missed
        // Set off by an earlier hold and not set back (the app didn't answer then): on, as far as is known.
        let owes = owed.contains(pid)
        var h = Hold(was: owes ? true : was, turnedOff: false, owners: [ObjectIdentifier(owner)], off: !missed && was != true)
        if missed {
            DragTrace.log("enhanced UI: pid \(pid) not held: no answer to the read (hung or busy); its windows are moved with it as it is")
        } else if was == true {
            if !write(adding: pid) {
                DragTrace.log("enhanced UI: pid \(pid) set off without a record for a crash (no start time, or \(journal.path) not writable)")
            }
            timedSet(pid, false, wait: wait)
            let now = timedRead(pid, wait: wait, why: "read back")
            // What the read says decides, not the set's answer. No answer: it may still land, so it is set back all the same.
            h.turnedOff = now == false || app.missed
            h.off = now == false
            if !h.turnedOff {
                DragTrace.log("enhanced UI: pid \(pid) still on after the set: its windows' sets stay animated")
                if !owes { write(removing: pid) }
            }
        } else if owes, was == false {
            h.turnedOff = true
        } else {
            DragTrace.log("enhanced UI: pid \(pid) \(was == false ? "already off" : "has none"): nothing set")
        }
        if h.turnedOff { owed.remove(pid) }
        holds[pid] = h
        return Held(off: h.off, missed: missed)
    }

    /// `owner`'s motion is over. The last of the app's holds sets the flag
    /// back to what it was, when the hold set it off: read back, and set once
    /// more if it didn't take (`retries`).
    /// `readsBack`: whether there is time to read it back (quitting has its
    /// bound); not, it is kept on record, set back at the next launch if it
    /// didn't take.
    func release(_ pid: pid_t, by owner: AnyObject, wait: Double = AXWindow.callLimit, retries: Int = 1, readsBack: () -> Bool = { true }) {
        guard var h = holds[pid], h.owners.remove(ObjectIdentifier(owner)) != nil else { return }
        guard h.owners.isEmpty else { holds[pid] = h; return }
        holds[pid] = nil
        guard h.turnedOff else { return }
        let want = h.was ?? true
        for attempt in 0...retries {
            timedSet(pid, want, wait: wait)
            guard readsBack() else {
                DragTrace.log("enhanced UI: pid \(pid) set back to \(want), no time to read it back: kept on record")
                if app.missed { owed.insert(pid) }
                return
            }
            let now = timedRead(pid, wait: wait, why: "read back")
            if now == want {
                write(removing: pid)
                return
            }
            DragTrace.log("enhanced UI: pid \(pid) is \(now.map { "\($0)" } ?? "unread") after setting it back to \(want)\(attempt < retries ? ": once more" : "")")
            if app.missed { break }
        }
        owed.insert(pid)
    }

    @discardableResult
    private func timedRead(_ pid: pid_t, wait: Double, why: String) -> Bool? {
        let began = CACurrentMediaTime()
        let v = app.read(pid, wait: wait)
        DragTrace.log(String(format: "enhanced UI: pid %d %@ %@ in %.2f ms", pid, why, app.missed ? "no answer" : v.map { "\($0)" } ?? "none",
                             (CACurrentMediaTime() - began) * 1000))
        return v
    }

    private func timedSet(_ pid: pid_t, _ on: Bool, wait: Double) {
        let began = CACurrentMediaTime()
        let ok = app.set(pid, on, wait: wait)
        DragTrace.log(String(format: "enhanced UI: pid %d set %@, answer %d%@, in %.2f ms", pid, on ? "on" : "off", app.lastAnswer,
                             ok ? "" : app.missed ? " (no answer)" : " (read back to see whether it took)", (CACurrentMediaTime() - began) * 1000))
    }

    /// At launch: sets back every flag a betterlink that stopped mid-motion
    /// left off, for each browser that is still the same process. Read back.
    func recover() {
        let entries = read()
        guard !entries.isEmpty else { return }
        var kept: [Entry] = []
        for e in entries {
            guard let l = app.launched(e.pid), abs(l.timeIntervalSince1970 - e.launched) < 1 else {
                DragTrace.log("enhanced UI: pid \(e.pid) recorded off, no longer that process: left alone")
                continue
            }
            timedSet(e.pid, e.was, wait: AXWindow.callLimit)
            let now = timedRead(e.pid, wait: AXWindow.callLimit, why: "read back at launch")
            if now != e.was { kept.append(e) }
        }
        save(kept)
    }

    // MARK: - The record

    struct Entry: Codable, Equatable {
        var pid: pid_t
        /// When its process started, seconds since 1970.
        var launched: Double
        var was: Bool
    }

    func read() -> [Entry] {
        (try? Data(contentsOf: journal)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Records the flip before it is made. False when it can't be recorded
    /// (or the process can't be told from a later one): then it isn't made.
    private func write(adding pid: pid_t) -> Bool {
        guard let launched = app.launched(pid) else { return false }
        var all = read().filter { $0.pid != pid }
        all.append(Entry(pid: pid, launched: launched.timeIntervalSince1970, was: true))
        return save(all)
    }

    private func write(removing pid: pid_t) {
        let all = read()
        if all.contains(where: { $0.pid == pid }) { save(all.filter { $0.pid != pid }) }
    }

    @discardableResult
    private func save(_ entries: [Entry]) -> Bool {
        do {
            if entries.isEmpty {
                if FileManager.default.fileExists(atPath: journal.path) { try FileManager.default.removeItem(at: journal) }
                return true
            }
            try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: journal, options: .atomic)
            return true
        } catch {
            DragTrace.log("enhanced UI: can't write \(journal.path): \(error)")
            return false
        }
    }

    /// Tests: forgets every hold (a rig left mid-motion by the case before).
    func forgetHolds() {
        holds = [:]
        owed = []
    }
}

/// A browser app's flag through Accessibility, on its application element.
@MainActor
final class AXEnhancedUIApp: EnhancedUIApp {
    private static let attribute = "AXEnhancedUserInterface" as CFString
    private(set) var missed = false
    private(set) var lastAnswer: Int32 = 0

    private func element(_ pid: pid_t, _ wait: Double) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Float(wait))
        return app
    }

    func read(_ pid: pid_t, wait: Double) -> Bool? {
        var v: CFTypeRef?
        let answer = AXUIElementCopyAttributeValue(element(pid, wait), Self.attribute, &v)
        missed = answer == .cannotComplete
        guard answer == .success, let v else { return nil }
        return (v as? NSNumber)?.boolValue
    }

    func set(_ pid: pid_t, _ on: Bool, wait: Double) -> Bool {
        let answer = AXUIElementSetAttributeValue(element(pid, wait), Self.attribute, (on ? kCFBooleanTrue : kCFBooleanFalse) as CFTypeRef)
        missed = answer == .cannotComplete
        lastAnswer = answer.rawValue
        return answer == .success
    }

    /// When the process started, from the kernel (`kp_proc.p_starttime`):
    /// every process has one, whoever started it.
    func launched(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }
}
