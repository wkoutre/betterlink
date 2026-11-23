import Foundation
import Testing
@testable import BetterlinkCore

/// Dia refuses a second process, so a Dia profile must never be opened with
/// the fresh-process command line other Chromium browsers get.
@Suite struct DiaSpaceTests {
    let dia = "company.thebrowser.dia"
    var work: BrowserProfile { BrowserProfile(browser: dia, directory: "Profile 2", name: "Work", color: nil) }

    @Test func diaSwitchesSpaceByScriptInsteadOfANewProcess() throws {
        let plan = try LaunchPlan.make(profile: work, argument: "https://a.com/",
                                       catalog: ProfileCatalog(profiles: [work]), ownBundleId: "dev.betterlink").get()
        #expect(plan.bundleId == dia)
        #expect(plan.mode == .switchSpace(name: "Work", link: "https://a.com/"))
        #expect(plan.arguments.isEmpty)
    }

    @Test func onlyDiaSwitchesByScript() {
        #expect(Browser.known.filter(\.switchesProfileByScript).map(\.bundleId) == [dia])
    }

    @Test func otherChromiumBrowsersStillUseTheCommandLine() throws {
        let chrome = BrowserProfile(browser: "com.google.Chrome", directory: "Profile 2", name: "Work", color: nil)
        let plan = try LaunchPlan.make(profile: chrome, argument: "https://a.com/",
                                       catalog: ProfileCatalog(profiles: [chrome]), ownBundleId: "dev.betterlink").get()
        #expect(plan.mode == .commandLine(["--profile-directory=Profile 2", "--", "https://a.com/"]))
    }

    /// The stored name wins over the one the rule carries, so a renamed
    /// profile still finds its space.
    @Test func usesTheCatalogName() throws {
        let stale = BrowserProfile(browser: dia, directory: "Profile 2", name: "Old", color: nil)
        let plan = try LaunchPlan.make(profile: stale, argument: "https://a.com/",
                                       catalog: ProfileCatalog(profiles: [work]), ownBundleId: "dev.betterlink").get()
        #expect(plan.mode == .switchSpace(name: "Work", link: "https://a.com/"))
    }

    @Test func diaStillRefusesUnsafeLinksAndUnknownProfiles() {
        let catalog = ProfileCatalog(profiles: [work])
        #expect(LaunchPlan.make(profile: work, argument: "javascript:alert(1)", catalog: catalog,
                                ownBundleId: "dev.betterlink") == .failure(.unsafeArgument))
        let other = BrowserProfile(browser: dia, directory: "Profile 9", name: "Nope", color: nil)
        #expect(LaunchPlan.make(profile: other, argument: "https://a.com/", catalog: catalog,
                                ownBundleId: "dev.betterlink") == .failure(.unknownProfile("Profile 9")))
    }

    @Test(arguments: ["", "a\nb", "x\u{7F}"])
    func spaceNamesWithControlCharactersAreRefused(name: String) {
        let p = BrowserProfile(browser: dia, directory: "Profile 2", name: name, color: nil)
        #expect(LaunchPlan.make(profile: p, argument: "https://a.com/", catalog: ProfileCatalog(profiles: [p]),
                                ownBundleId: "dev.betterlink") == .failure(.unknownProfile("Profile 2")))
    }

    /// The name is an argument, never part of the script source.
    @Test func spaceNameTravelsAsAnArgument() {
        let name = "x\" & (do shell script \"id\") & \""
        let args = DiaSpace.osascriptArguments(space: name)
        #expect(args == ["-e", DiaSpace.script, "--", name])
        #expect(!DiaSpace.script.contains(name))
        #expect(DiaSpace.script.contains("focus p"))
        #expect(DiaSpace.script.contains("profile spaceName of w"))
    }

    /// osascript reads an argument starting with "-" as an option unless
    /// "--" comes first, so a space named "-e <code>" would run that code.
    @Test func spaceNameCanNotBeAnOption() {
        for name in ["-eproperty x : (do shell script \"touch /tmp/x\")", "-Work", "--", "-l"] {
            let args = DiaSpace.osascriptArguments(space: name)
            #expect(args.count == 4 && args[2] == "--" && args[3] == name)
        }
    }

    @Test func outcomes() {
        typealias O = DiaSpace.Outcome
        #expect(O.parse(status: 0, output: "focused\n", error: "") == .focused)
        #expect(O.parse(status: 0, output: "nospace\n", error: "") == .noSuchSpace)
        #expect(O.parse(status: 0, output: "nowindow\n", error: "") == .noWindow)
        #expect(O.parse(status: 1, output: "", error: "execution error: Not authorized to send Apple events to Dia. (-1743)") == .notAllowed)
        #expect(O.parse(status: 1, output: "", error: "boom") == .failed("boom"))
        #expect(O.parse(status: 1, output: "", error: "") == .failed("osascript exited with 1"))
        #expect(O.focused.note(space: "Work") == nil)
        #expect(O.noSuchSpace.note(space: "Work")?.contains("current space") == true)
        #expect(O.notAllowed.note(space: "Work")?.contains("Automation") == true)
    }

    /// Security audit, Nov 2026 (M7): when Dia can't show the link's space it
    /// would open the link in whichever space is in front, so a link ruled
    /// into one profile could land in another. It goes to the fallback instead.
    @Test func onlyFocusedCountsAsSwitched() {
        typealias O = DiaSpace.Outcome
        #expect(O.focused.switched)
        for o in [O.noSuchSpace, .noWindow, .notAllowed, .failed("boom")] { #expect(!o.switched) }
    }

    @Test func aFailedSwitchSendsTheLinkToTheFallbackProfile() throws {
        let chrome = BrowserProfile(browser: "com.google.Chrome", directory: "Default", name: "Personal", color: nil)
        let catalog = ProfileCatalog(profiles: [work, chrome])
        let plan = try LaunchPlan.make(profile: work, argument: "https://a.com/x?y=1", catalog: catalog,
                                       ownBundleId: "dev.betterlink").get()
        let other = try #require(plan.afterFailedSwitch(fallback: chrome.ref, catalog: catalog, ownBundleId: "dev.betterlink"))
        #expect(other.bundleId == "com.google.Chrome")
        #expect(other.mode == .commandLine(["--profile-directory=Default", "--", "https://a.com/x?y=1"]))
    }

    /// The fallback is allowed even when it isn't a stored profile, as for any link.
    @Test func theFallbackNeedNotBeStored() throws {
        let catalog = ProfileCatalog(profiles: [work])
        let plan = try LaunchPlan.make(profile: work, argument: "https://a.com/", catalog: catalog,
                                       ownBundleId: "dev.betterlink").get()
        let fallback = ProfileRef(browser: "com.google.Chrome", directory: "Default")
        let other = try #require(plan.afterFailedSwitch(fallback: fallback, catalog: catalog, ownBundleId: "dev.betterlink"))
        #expect(other.mode == .commandLine(["--profile-directory=Default", "--", "https://a.com/"]))
    }

    /// A link that was headed for the fallback has nowhere else to go.
    @Test func noOtherPlaceWhenTheSpaceIsTheFallback() throws {
        let catalog = ProfileCatalog(profiles: [work])
        let plan = try LaunchPlan.make(profile: work, argument: "https://a.com/", catalog: catalog,
                                       ownBundleId: "dev.betterlink").get()
        #expect(plan.afterFailedSwitch(fallback: work.ref, catalog: catalog, ownBundleId: "dev.betterlink") == nil)
    }

    /// A fallback in another Dia space is a second switch, tried once.
    @Test func aFallbackInAnotherDiaSpaceIsAnotherSwitch() throws {
        let home = BrowserProfile(browser: dia, directory: "Default", name: "Home", color: nil)
        let catalog = ProfileCatalog(profiles: [work, home])
        let plan = try LaunchPlan.make(profile: work, argument: "https://a.com/", catalog: catalog,
                                       ownBundleId: "dev.betterlink").get()
        let other = try #require(plan.afterFailedSwitch(fallback: home.ref, catalog: catalog, ownBundleId: "dev.betterlink"))
        #expect(other.mode == .switchSpace(name: "Home", link: "https://a.com/"))
        #expect(other.afterFailedSwitch(fallback: home.ref, catalog: catalog, ownBundleId: "dev.betterlink") == nil)
    }

    @Test func onlyASpaceSwitchHasAFallbackPlan() throws {
        let chrome = BrowserProfile(browser: "com.google.Chrome", directory: "Profile 2", name: "Work", color: nil)
        let catalog = ProfileCatalog(profiles: [chrome, work])
        let plan = try LaunchPlan.make(profile: chrome, argument: "https://a.com/", catalog: catalog,
                                       ownBundleId: "dev.betterlink").get()
        #expect(plan.afterFailedSwitch(fallback: work.ref, catalog: catalog, ownBundleId: "dev.betterlink") == nil)
    }

    /// betterlink as its own fallback would hand the link back to itself.
    @Test func noFallbackPlanThatTargetsBetterlinkItself() throws {
        let catalog = ProfileCatalog(profiles: [work])
        let plan = try LaunchPlan.make(profile: work, argument: "https://a.com/", catalog: catalog,
                                       ownBundleId: "dev.betterlink").get()
        let own = ProfileRef(browser: "dev.betterlink", directory: "Default")
        #expect(plan.afterFailedSwitch(fallback: own, catalog: catalog, ownBundleId: "dev.betterlink") == nil)
    }

    @Test func notesSayWhereTheLinkWent() {
        typealias O = DiaSpace.Outcome
        #expect(O.focused.note(space: "Work", openedIn: "Personal") == nil)
        #expect(O.noSuchSpace.note(space: "Work", openedIn: "Personal")
                == "Dia has no space named \"Work\", so the link opened in Personal instead.")
        #expect(O.notAllowed.note(space: "Work", openedIn: "Personal")
                == "betterlink isn't allowed to control Dia, so the link opened in Personal instead. Allow it in System Settings › Privacy & Security › Automation.")
        #expect(O.failed("boom").note(space: "Work", openedIn: "Personal")
                == "Couldn't switch Dia to \"Work\" (boom), so the link opened in Personal instead.")
        // With nowhere else to send it, Dia still gets the link.
        #expect(O.noWindow.note(space: "Work") == "Dia had no window to switch to \"Work\", so the link opened wherever Dia put it.")
        #expect(O.failed("boom").note(space: "Work") == "Couldn't switch Dia to \"Work\" (boom), so the link opened in the current space.")
    }
}
