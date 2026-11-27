import AppKit
import BetterlinkCore
import CoreGraphics
import Sparkle

/// Sparkle, set up once. It checks the release feed (SUFeedURL in Info.plist)
/// once an hour when automatic checks are on and verifies every update against
/// the EdDSA key in Info.plist and Apple's notarization. With automatic
/// installs on (the default) it downloads the update in the background and
/// betterlink restarts into it the next time nobody has touched the Mac for
/// two minutes, or when it quits. With them off, it asks first. Off entirely
/// in builds without an update key and under BETTERLINK_HOME.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    /// Sparkle holds its delegates weakly.
    private let delegate: UpdaterDelegate

    /// Mirrors Sparkle's setting so SwiftUI can bind to it.
    @Published var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            if let updater = controller?.updater { updater.automaticallyChecksForUpdates = automaticallyChecks }
            else { UpdateChecks.setAutomatic(automaticallyChecks, in: UpdateChecks.defaults()) }
        }
    }

    /// Mirrors Sparkle's automatic download and install setting.
    @Published var installsAutomatically: Bool {
        didSet {
            guard installsAutomatically != oldValue else { return }
            if let updater = controller?.updater { updater.automaticallyDownloadsUpdates = installsAutomatically }
            else { UpdateChecks.setInstallsAutomatically(installsAutomatically, in: UpdateChecks.defaults()) }
        }
    }

    /// A downloaded update waiting to install ("0.3.30"), shown in the menu
    /// and on the General page with a way to restart into it now.
    @Published private(set) var readyVersion: String?
    /// An update Sparkle found and is asking about (automatic installs off, or
    /// one that can't install by itself), so the menu can bring it back.
    @Published private(set) var foundVersion: String?
    private var installNow: (() -> Void)?
    private var idleTimer: Timer?

    var isAvailable: Bool { controller != nil }

    private init() {
        let delegate = UpdaterDelegate()
        self.delegate = delegate
        if UpdateChecks.updaterCanRun(info: Bundle.main.infoDictionary ?? [:]) {
            UpdateChecks.applyInstallDefault(in: UpdateChecks.defaults())
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: delegate)
        } else {
            controller = nil
        }
        automaticallyChecks = UpdateChecks.isAutomatic(in: UpdateChecks.defaults())
        installsAutomatically = UpdateChecks.installsAutomatically(in: UpdateChecks.defaults())
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// Installs the waiting update and restarts betterlink.
    func restartToUpdate() {
        guard let install = installNow else { return }
        // Kept until betterlink actually quits: Sparkle allows calling it
        // again, so if the restart doesn't happen the menu and the idle
        // install still work.
        stopIdleTimer()
        install()
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) {
            if self.installNow != nil { self.startIdleTimer() }
        }
    }

    /// `betterlink updates set` changed a setting from another process.
    func reloadSetting() {
        let d = UpdateChecks.defaults()
        let on = UpdateChecks.isAutomatic(in: d)
        if on != automaticallyChecks { automaticallyChecks = on }
        let install = UpdateChecks.installsAutomatically(in: d)
        if install != installsAutomatically { installsAutomatically = install }
    }

    // MARK: From Sparkle (UpdaterDelegate)

    /// The update is downloaded and Sparkle would install it at quit. A menu
    /// bar app rarely quits, so install it once the Mac has been left alone.
    fileprivate func updateReady(version: String, install: @escaping () -> Void) {
        readyVersion = version
        installNow = install
        startIdleTimer()
    }

    fileprivate func updateFound(version: String) {
        if readyVersion == nil { foundVersion = version }
    }

    fileprivate func sessionEnded() {
        foundVersion = nil
        // Sparkle's prompt has its own "install automatically" box.
        if let updater = controller?.updater, updater.automaticallyDownloadsUpdates != installsAutomatically {
            installsAutomatically = updater.automaticallyDownloadsUpdates
        }
    }

    private func startIdleTimer() {
        stopIdleTimer()
        // Runs only while an update waits, so an up to date betterlink keeps no timer.
        let timer = Timer(timeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { Updater.shared.installIfIdle() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    private func stopIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func installIfIdle() {
        guard installsAutomatically, installNow != nil else { return }
        if UpdateChecks.shouldInstallNow(idleSeconds: Self.secondsSinceInput()) { restartToUpdate() }
    }

    /// Seconds since the last key press, click, scroll or mouse move. Reading
    /// it needs no permission.
    private static func secondsSinceInput() -> TimeInterval {
        // ~0 is kCGAnyInputEventType, which Swift doesn't name.
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
    }
}

/// Sparkle's two delegates. Sparkle calls them on the main thread.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated { Updater.shared.updateReady(version: version, install: immediateInstallHandler) }
        return true  // betterlink offers it (menu, General page) and installs it when the Mac is idle
    }

    // betterlink has no Dock icon, so a prompt for a check nobody asked for
    // opens behind the app in use (Sparkle won't pull focus mid work). The
    // menu bar menu then offers "Update to betterlink X…" to bring it back.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        MainActor.assumeIsolated { Updater.shared.updateFound(version: version) }
    }

    func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { Updater.shared.sessionEnded() }
    }
}
