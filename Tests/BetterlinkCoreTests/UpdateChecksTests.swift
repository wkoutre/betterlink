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

    /// Sparkle reads this key, so a rename would silently stop the switch working.
    @Test func usesSparklesKey() {
        #expect(UpdateChecks.defaultsKey == "SUEnableAutomaticChecks")
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
        // The shipped app trusts exactly this update key; a release signed with any other never installs.
        #expect(UpdateChecks.updaterCanRun(info: info, environment: [:]))
    }
}
