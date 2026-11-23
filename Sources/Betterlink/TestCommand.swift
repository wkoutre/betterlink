import AppKit
import BetterlinkCore
import Foundation

/// `betterlink --test <link> [--keys control,command]`: one decision,
/// printed, with nothing opened. --keys pretends those modifier keys are held.
enum TestCommand {
    static func run(link: String, keys: ModifierKeys = []) -> Int32 {
        let stored: RuleStore.Contents
        do { stored = try RuleStore(folder: .resolve()).load() } catch {
            print("rules.json: \(error)"); return 2
        }
        let rules = stored.rules
        let installed = Browser.known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }
        let catalog = ProfileCatalog(profiles: stored.profiles ?? []).addingPlain(installed: installed)
        var script: ConfigScript?
        let ts = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("typescript")
        if let compiler = try? TypeScriptCompiler(typescriptJS: ts.appendingPathComponent("typescript.js"),
                                                  libDirectory: ts.appendingPathComponent("lib")) {
            switch ConfigLoader.load(paths: .resolve(), compiler: compiler, catalog: catalog, log: { print("config.ts: \($0)") }) {
            case .absent: break
            case .loaded(let s): script = s
            case .failed(let e): print("config.ts not loaded: \(e)")
            }
        } else {
            print("TypeScript compiler not found in \(ts.path); config.ts ignored")
        }
        let fallback = Agent.effectiveFallback(stored.fallback, installed: installed)
        let d = Router(rules: rules, modifierRules: stored.modifierRules ?? [], script: script, catalog: catalog,
                       fallback: fallback).decide(link, modifiers: keys)
        switch d.action {
        case .refuse: print("refuse\t\(d.reason)")
        case .open(let p, let arg): print("\(p.browser)\t\(p.directory)\t\(p.name)\t\(arg)\t\(d.reason)")
        }
        return 0
    }
}

/// `betterlink --import-profiles`: copies every installed browser's profile list into
/// betterlink's settings. Run it from Terminal, which macOS lets read the
/// browser's data when betterlink itself can't.
enum ImportProfilesCommand {
    static func run() -> Int32 {
        // The same import the CLI's `profiles import` runs.
        AgentCommand.run(["profiles.import"])
    }
}
