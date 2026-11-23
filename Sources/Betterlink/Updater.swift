import AppKit
import BetterlinkCore
import Sparkle

/// Sparkle, set up once. It checks the release feed (SUFeedURL in Info.plist)
/// once a day when automatic checks are on, verifies every update against the
/// EdDSA key in Info.plist and Apple's notarization, then offers Install or
/// Skip. Off entirely in builds without an update key and under
/// BETTERLINK_HOME.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    /// Mirrors Sparkle's setting so SwiftUI can bind to it.
    @Published var automaticallyChecks: Bool {
        didSet {
            guard automaticallyChecks != oldValue else { return }
            if let updater = controller?.updater { updater.automaticallyChecksForUpdates = automaticallyChecks }
            else { UpdateChecks.setAutomatic(automaticallyChecks, in: UpdateChecks.defaults()) }
        }
    }

    var isAvailable: Bool { controller != nil }

    private init() {
        if UpdateChecks.updaterCanRun(info: Bundle.main.infoDictionary ?? [:]) {
            controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        } else {
            controller = nil
        }
        automaticallyChecks = UpdateChecks.isAutomatic(in: UpdateChecks.defaults())
    }

    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    /// `betterlink updates set` changed the setting from another process.
    func reloadSetting() {
        let on = UpdateChecks.isAutomatic(in: UpdateChecks.defaults())
        if on != automaticallyChecks { automaticallyChecks = on }
    }
}
