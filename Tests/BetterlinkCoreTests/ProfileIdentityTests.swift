import Foundation
import Testing
@testable import BetterlinkCore

struct ProfileIdentityTests {
    let localState = Data("""
    {"profile":{"info_cache":{
      "Default":{"name":"Personal","user_name":"me@gmail.com"},
      "Profile 2":{"name":"Work","user_name":"me@work.com"},
      "Profile 3":{"name":"Shopping","user_name":""}}}}
    """.utf8)

    @Test func accountsComeFromLocalState() {
        #expect(ProfileCatalog.accounts(localStateJSON: localState) == ["Default": "me@gmail.com", "Profile 2": "me@work.com"])
    }

    @Test func aRuleFindsItsProfileByAccountThenName() {
        let profiles = ProfileCatalog.parse(localStateJSON: localState, browser: "com.google.Chrome").profiles
        let acc = ProfileCatalog.accounts(localStateJSON: localState)
        // On the other Mac "Work" was Profile 1; here it is Profile 2, found by account.
        #expect(ProfileCatalog.resolve(ProfileIdentity(name: "Job", account: "me@work.com"), profiles: profiles, accounts: acc) == "Profile 2")
        // No account: by name.
        #expect(ProfileCatalog.resolve(ProfileIdentity(name: "Shopping", account: nil), profiles: profiles, accounts: acc) == "Profile 3")
        // Neither on this Mac.
        #expect(ProfileCatalog.resolve(ProfileIdentity(name: "Gone", account: "x@y.com"), profiles: profiles, accounts: acc) == nil)
    }

    @Test func onlyChromiumRulesAreMatchedThroughLocalState() {
        let chrome = Browser.known(bundleId: "com.google.Chrome")
        let firefox = Browser.known(bundleId: "org.mozilla.firefox")
        let who = ProfileIdentity(name: "Work", account: "me@work.com")
        // Firefox has profiles.ini, not Local State: its rules apply as they are.
        #expect(ProfileCatalog.resolveSynced(browser: firefox, directory: "default-release", identity: who, localState: nil) == "default-release")
        // An unknown browser too.
        #expect(ProfileCatalog.resolveSynced(browser: nil, directory: "X", identity: who, localState: nil) == "X")
        // A Chromium browser whose Local State can't be read: nothing to check against, keep it.
        #expect(ProfileCatalog.resolveSynced(browser: chrome, directory: "Profile 1", identity: who, localState: nil) == "Profile 1")
        // Readable Local State: found by account.
        #expect(ProfileCatalog.resolveSynced(browser: chrome, directory: "Profile 1", identity: who, localState: localState) == "Profile 2")
        // Not on this Mac.
        #expect(ProfileCatalog.resolveSynced(browser: chrome, directory: "Profile 2", identity: ProfileIdentity(name: "Gone", account: "x@y.com"),
                                             localState: localState) == nil)
    }

    @Test func twoProfilesWithOneNameKeepTheFolderThatMatches() {
        let twin = Data("""
        {"profile":{"info_cache":{"Default":{"name":"Me"},"Profile 2":{"name":"Me"}}}}
        """.utf8)
        let chrome = Browser.known(bundleId: "com.google.Chrome")
        #expect(ProfileCatalog.resolveSynced(browser: chrome, directory: "Profile 2", identity: ProfileIdentity(name: "Me", account: nil),
                                             localState: twin) == "Profile 2")
    }
}
