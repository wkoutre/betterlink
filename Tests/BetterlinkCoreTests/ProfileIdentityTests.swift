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
}
