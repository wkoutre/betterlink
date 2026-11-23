import Foundation
import Testing
@testable import BetterlinkCore

struct LinkToastTests {
    private func fresh() -> UserDefaults {
        let name = "betterlink.tests.toast.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func onAndAtTheTopUntilChanged() {
        let d = fresh()
        #expect(LinkToast.isShown(in: d))
        #expect(LinkToast.position(in: d) == .top)
        LinkToast.setShown(false, in: d)
        LinkToast.setPosition(.bottom, in: d)
        #expect(!LinkToast.isShown(in: d))
        #expect(LinkToast.position(in: d) == .bottom)
        d.set("sideways", forKey: LinkToast.positionKey)
        #expect(LinkToast.position(in: d) == .top)
    }

    /// Only a rule choosing the profile shows a toast, never the fallback.
    @Test func saysWhatChoseTheProfile() {
        struct Script: LinkScript {
            func route(_ link: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict {
                link.host == "script.com" ? .profile("Work") : .noOpinion
            }
        }
        let r = Router(rules: [Rule(kind: .domain, pattern: "acme.com", profile: "Profile 1")],
                       modifierRules: [ModifierRule(keys: [.control, .command], profile: "Profile 1")],
                       script: Script(), catalog: catalog, fallback: ProfileRef(stored: "Default"))
        func toast(_ link: String, _ keys: ModifierKeys = []) -> String? {
            LinkToast.message(for: r.decide(link, modifiers: keys)).map { "\($0.profile.name) · \($0.detail)" }
        }
        #expect(toast("https://acme.com/") == "Work · Rule 1")
        #expect(toast("https://script.com/") == "Work · config.ts")
        #expect(toast("https://other.com/", [.control, .command]) == "Work · Holding ⌃⌘")
        #expect(toast("https://other.com/") == nil)
        #expect(toast("javascript:alert(1)") == nil)
        // A rule naming a missing profile falls back: no toast.
        let missing = Router(rules: [Rule(kind: .domain, pattern: "acme.com", profile: "Profile 9")], script: nil,
                             catalog: catalog, fallback: ProfileRef(stored: "Default"))
        #expect(LinkToast.message(for: missing.decide("https://acme.com/")) == nil)
    }
}
