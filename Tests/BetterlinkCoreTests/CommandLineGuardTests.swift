import Foundation
import Testing
@testable import BetterlinkCore

/// Security audit, Nov 2026: started with `open -n -a betterlink.app --args
/// agent …`, the command ran with the app's own Full Disk Access, and
/// `folder.set` and `config.check` then read files for a caller that may not.
@Suite struct CommandLineGuardTests {
    @Test func refusesWhenBetterlinkIsResponsibleForItself() {
        // Started through LaunchServices or launchd: the app's own grants apply.
        let why = CommandLineGuard.refusal(ownPid: 4242, responsiblePid: 4242)
        #expect(why?.contains("terminal") == true)
    }

    @Test func runsWhenTheCallerIsResponsible() {
        // A terminal, script or agent started it: the caller's grants apply.
        #expect(CommandLineGuard.refusal(ownPid: 4242, responsiblePid: 311) == nil)
    }

    @Test func runsWhenMacOSDoesNotSay() {
        // Refusing here would break the command for everyone.
        #expect(CommandLineGuard.refusal(ownPid: 4242, responsiblePid: nil) == nil)
    }

    /// The lookup is a symbol no public header declares. If a macOS release
    /// drops it, the guard silently stops guarding; this test says so.
    /// (That the command still runs from a shell is what `make test-cli` checks.)
    @Test func macOSStillSaysWhoIsResponsible() throws {
        let responsible = try #require(CommandLineGuard.responsiblePid())
        #expect(responsible > 0)
    }
}
