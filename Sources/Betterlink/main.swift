import AppKit
import BetterlinkCore

// `betterlink --test <link>` prints where a link would open, without opening
// it, using the installed rules, config.ts and profiles.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--test"), args.indices.contains(i + 1) {
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
if args.count > 1 && args[1] == "agent" { exit(AgentCommand.run(Array(args.dropFirst(2)))) }

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
