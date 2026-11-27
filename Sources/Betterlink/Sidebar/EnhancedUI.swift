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
    /// Sets it: one Accessibility call. False when the app didn't take it.
    func set(_ pid: pid_t, _ on: Bool, wait: Double) -> Bool
    /// The last call got no answer in time: the app is hung or busy.
    var missed: Bool { get }
    /// When the process with this pid started, to tell it from a later
    /// process given the same pid. Nil when none runs.
    func launched(_ pid: pid_t) -> Date?
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
///   off (one call), and only once the flip is written down (below).
/// - Right after the motion's final target has landed (or the motion is
///   capped, taken over by someone else, given up, or the window closes),
///   it is set back to what it was (one call). Never per frame, never for
///   a motion that moves nothing, never when it was off already.
/// - Several of the browser's windows moving at once share one hold: the
///   flag goes back once the last of them is done.
/// - Only the browser whose window is being moved is touched.
///
/// Crash safety: before a flag is set off, the browser's pid, the time its
/// process started and the value it had are written to `enhanced-ui.json`
/// in betterlink's settings folder (this Mac's, never the sync folder), and
/// removed once it is set back. If betterlink stops in between (a crash, a
/// force quit), the next launch (`recover`) sets the flag back for each
/// recorded browser that is still the same process: the same pid started at
/// the same time. A pid since reused by another process started later, so
/// it is never touched. A browser that doesn't answer when its flag is set
/// back (hung) keeps its entry: the next hold of it sets it back after its
/// motion, and the next launch does if none comes.
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

    /// Holds `pid`'s flag off for `owner`'s motion: read, and set off if it
    /// is on. `wait`: how long each call may wait for the app.
    @discardableResult
    func hold(_ pid: pid_t, by owner: AnyObject, wait: Double = AXWindow.callLimit) -> Held {
        if var h = holds[pid] {
            h.owners.insert(ObjectIdentifier(owner))
            holds[pid] = h
            return Held(off: h.off, missed: false)
        }
        let began = CACurrentMediaTime()
        let was = app.read(pid, wait: wait)
        let missed = app.missed
        DragTrace.log(String(format: "enhanced UI: pid %d read %@ in %.2f ms", pid, missed ? "no answer" : was.map { "\($0)" } ?? "none",
                             (CACurrentMediaTime() - began) * 1000))
        // Set off by an earlier hold and not set back (the app didn't answer then): on, as far as is known.
        let owes = owed.contains(pid)
        var h = Hold(was: owes ? true : was, turnedOff: false, owners: [ObjectIdentifier(owner)], off: !missed && was != true)
        if owes, !missed, was == false {
            h.turnedOff = true
        } else if was == true, !missed, write(adding: pid) {
            let at = CACurrentMediaTime()
            let took = app.set(pid, false, wait: wait)
            DragTrace.log(String(format: "enhanced UI: pid %d set off %@ in %.2f ms", pid, took ? "taken" : app.missed ? "no answer" : "refused",
                                 (CACurrentMediaTime() - at) * 1000))
            // A set that got no answer may still land: set back all the same.
            h.turnedOff = took || app.missed
            h.off = took
            if !h.turnedOff, !owes { write(removing: pid) }
        }
        if h.turnedOff { owed.remove(pid) }
        holds[pid] = h
        return Held(off: h.off, missed: missed)
    }

    /// `owner`'s motion is over. The last of the app's holds sets the flag
    /// back to what it was, when the hold set it off.
    func release(_ pid: pid_t, by owner: AnyObject, wait: Double = AXWindow.callLimit) {
        guard var h = holds[pid], h.owners.remove(ObjectIdentifier(owner)) != nil else { return }
        guard h.owners.isEmpty else { holds[pid] = h; return }
        holds[pid] = nil
        guard h.turnedOff else { return }
        let began = CACurrentMediaTime()
        let took = app.set(pid, h.was ?? true, wait: wait)
        DragTrace.log(String(format: "enhanced UI: pid %d set back to %@ %@ in %.2f ms", pid, "\(h.was ?? true)",
                             took ? "taken" : app.missed ? "no answer" : "refused", (CACurrentMediaTime() - began) * 1000))
        if took { write(removing: pid) } else { owed.insert(pid) }
    }

    /// At launch: sets back every flag a betterlink that stopped mid-motion
    /// left off, for each browser that is still the same process.
    func recover() {
        let entries = read()
        guard !entries.isEmpty else { return }
        var kept: [Entry] = []
        for e in entries {
            guard let l = app.launched(e.pid), abs(l.timeIntervalSince1970 - e.launched) < 1 else {
                DragTrace.log("enhanced UI: pid \(e.pid) recorded off, no longer that process: left alone")
                continue
            }
            let took = app.set(e.pid, e.was, wait: AXWindow.callLimit)
            DragTrace.log("enhanced UI: pid \(e.pid) recorded off, set back to \(e.was) at launch: \(took ? "taken" : "no answer")")
            if !took { kept.append(e) }
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
        return answer == .success
    }

    func launched(_ pid: pid_t) -> Date? { NSRunningApplication(processIdentifier: pid)?.launchDate }
}
