import AppKit
import BetterlinkCore

// `betterlink --test <link>` prints where a link would open, without opening
// it, using the installed rules, config.ts and profiles.
let args = CommandLine.arguments
let testIndex = args.firstIndex(of: "--test").flatMap { args.indices.contains($0 + 1) ? $0 : nil }
let isAgent = args.count > 1 && args[1] == "agent"
// The command-line modes read and copy files a settings folder names. They
// must run with the caller's permissions, never the app's own (see
// CommandLineGuard), so they refuse to start the way an app is started.
if testIndex != nil || isAgent || args.contains("--import-profiles"), let why = CommandLineGuard.refusal() {
    if isAgent {
        // The CLI reads one JSON envelope from standard output.
        FileHandle.standardOutput.write(AgentResponseJSON.failure(why) + Data("\n".utf8))
    } else {
        FileHandle.standardError.write(Data((why + "\n").utf8))
    }
    exit(1)
}
if let i = testIndex {
    var keys: ModifierKeys = []
    if let k = args.firstIndex(of: "--keys"), args.indices.contains(k + 1) {
        guard let parsed = ModifierKeys(names: args[k + 1].split(separator: ",").map(String.init)) else {
            print("--keys takes control, option, shift and command, separated by commas"); exit(2)
        }
        keys = parsed
    }
    exit(TestCommand.run(link: args[i + 1], keys: keys))
}
if args.contains("--import-profiles") { exit(ImportProfilesCommand.run()) }
// `betterlink agent <command> ['<json>']`: what the bundled CLI calls.
if isAgent { exit(AgentCommand.run(Array(args.dropFirst(2)))) }

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
