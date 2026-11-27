import Foundation
import Testing
@testable import BetterlinkCore

struct UpdateChecksTests {
    private func fresh() -> UserDefaults {
        let name = "betterlink.tests.updates.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func automaticUntilTurnedOff() {
        let d = fresh()
        #expect(UpdateChecks.isAutomatic(in: d))
        UpdateChecks.setAutomatic(false, in: d)
        #expect(!UpdateChecks.isAutomatic(in: d))
    }

    @Test func installsUntilTurnedOff() {
        let d = fresh()
        #expect(UpdateChecks.installsAutomatically(in: d))
        UpdateChecks.setInstallsAutomatically(false, in: d)
        #expect(!UpdateChecks.installsAutomatically(in: d))
        #expect(UpdateChecks.isAutomatic(in: d))  // the two switches are separate
    }

    /// Sparkle reads these keys, so a rename would silently stop the switches working.
    @Test func usesSparklesKeys() {
        #expect(UpdateChecks.defaultsKey == "SUEnableAutomaticChecks")
        #expect(UpdateChecks.installKey == "SUAutomaticallyUpdate")
    }

    /// An "off" left by Sparkle's prompt is turned on once; an "off" chosen
    /// after that stays.
    @Test func turnsInstallsOnOnceForExistingMacs() {
        let d = fresh()
        UpdateChecks.setInstallsAutomatically(false, in: d)
        #expect(UpdateChecks.applyInstallDefault(in: d))
        #expect(UpdateChecks.installsAutomatically(in: d))
        UpdateChecks.setInstallsAutomatically(false, in: d)
        #expect(!UpdateChecks.applyInstallDefault(in: d))
        #expect(!UpdateChecks.installsAutomatically(in: d))

        let unset = fresh()
        #expect(!UpdateChecks.applyInstallDefault(in: unset))
        #expect(unset.object(forKey: UpdateChecks.installKey) == nil)  // Info.plist's default still decides
        #expect(UpdateChecks.installsAutomatically(in: unset))
    }

    /// A downloaded update waits until nobody has touched the Mac for two minutes.
    @Test func installsOnlyWhenIdle() {
        #expect(!UpdateChecks.shouldInstallNow(idleSeconds: 0))
        #expect(!UpdateChecks.shouldInstallNow(idleSeconds: 119))
        #expect(UpdateChecks.shouldInstallNow(idleSeconds: 120))
        #expect(UpdateChecks.shouldInstallNow(idleSeconds: 3 * 3600))
        #expect(!UpdateChecks.shouldInstallNow(idleSeconds: .nan))
        #expect(!UpdateChecks.shouldInstallNow(idleSeconds: .infinity))
    }

    @Test func updaterNeedsAKeyAFeedAndNoTestFolder() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let feed = "https://github.com/wkoutre/betterlink/releases/latest/download/appcast.xml"
        #expect(UpdateChecks.updaterCanRun(info: ["SUPublicEDKey": key, "SUFeedURL": feed], environment: [:]))
        #expect(!UpdateChecks.updaterCanRun(info: ["SUPublicEDKey": key, "SUFeedURL": feed], environment: ["BETTERLINK_HOME": "/tmp/x"]))
        #expect(!UpdateChecks.updaterCanRun(info: ["SUPublicEDKey": "", "SUFeedURL": feed], environment: [:]))
        #expect(!UpdateChecks.updaterCanRun(info: ["SUPublicEDKey": "c2hvcnQ=", "SUFeedURL": feed], environment: [:]))
        #expect(!UpdateChecks.updaterCanRun(info: ["SUPublicEDKey": key, "SUFeedURL": "http://example.com/a.xml"], environment: [:]))
        #expect(!UpdateChecks.updaterCanRun(info: ["SUPublicEDKey": key], environment: [:]))
    }

    /// The shipped Info.plist: the feed must be the GitHub release feed, and
    /// the build number must equal the version, because Sparkle compares
    /// CFBundleVersion.
    @Test func infoPlistFeedAndVersions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Info.plist"))
        let info = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(info["SUFeedURL"] as? String == "https://github.com/wkoutre/betterlink/releases/latest/download/appcast.xml")
        #expect(info["CFBundleVersion"] as? String == info["CFBundleShortVersionString"] as? String)
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
        // Updates arrive by themselves: an hourly look (Sparkle's default is a
        // day, which left Macs a day behind), downloaded and installed without a prompt.
        #expect(info["SUScheduledCheckInterval"] as? Int == Int(UpdateChecks.checkInterval))
        #expect(UpdateChecks.checkInterval >= 3600)  // Sparkle's floor; less is ignored
        #expect(info["SUAutomaticallyUpdate"] as? Bool == true)
        #expect(info["SUAllowsAutomaticUpdates"] as? Bool == true)
        // The shipped app trusts exactly this update key; a release signed with any other never installs.
        #expect(UpdateChecks.updaterCanRun(info: info, environment: [:]))
    }
}
