import Foundation
import Testing
@testable import BetterlinkCore

/// Vendor/typescript is fetched by scripts/fetch-typescript.sh (make fetch).
private let vendor = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Vendor/typescript")

private let compiler: TypeScriptCompiler = {
    try! TypeScriptCompiler(typescriptJS: vendor.appendingPathComponent("typescript.js"),
                            libDirectory: vendor.appendingPathComponent("lib"))
}()

private let decls = configDeclarations(catalog: catalog)

private func script(_ ts: String) throws -> ConfigScript {
    let out = compiler.compile(ts, declarations: decls)
    guard let js = out.javascript else { throw ConfigError.compile(out.errors) }
    return try ConfigScript(javascript: js)
}

@Suite(.serialized) struct ConfigTests {
    @Test func typeChecksAgainstRealProfileNames() {
        let bad = compiler.compile("""
        export default function route(link: Link): ProfileName | undefined { return "Workk"; }
        """, declarations: decls)
        #expect(bad.javascript == nil)
        #expect(bad.errors.contains { $0.hasPrefix("config.ts:1:") && $0.contains("Workk") })

        let wrongField = compiler.compile("""
        export default function route(link: Link) { const n: number = link.host; return undefined; }
        """, declarations: decls)
        #expect(wrongField.javascript == nil)
    }

    @Test func routesWithTheCompiledFunction() throws {
        let s = try script("""
        export default function route(link: Link): ProfileName | undefined {
          if (link.opener === "com.tinyspeck.slackmacgap" && link.host.endsWith("acme.com")) return "Work";
          return undefined;
        }
        """)
        #expect(s.route(web("https://app.acme.com"), opener: "com.tinyspeck.slackmacgap") == .profile("Work"))
        #expect(s.route(web("https://app.acme.com"), opener: "com.apple.mail") == .noOpinion)
    }

    /// config.ts sees the modifier keys held when the link was clicked.
    @Test func scriptSeesTheHeldModifierKeys() throws {
        let s = try script("""
        export default function route(link: Link): ProfileName | undefined {
          if (link.modifiers.includes("option") && link.modifiers.length === 1) return "Work";
          return undefined;
        }
        """)
        #expect(s.route(web("https://a.com"), opener: nil, modifiers: [.option]) == .profile("Work"))
        #expect(s.route(web("https://a.com"), opener: nil, modifiers: [.option, .command]) == .noOpinion)
        #expect(s.route(web("https://a.com"), opener: nil) == .noOpinion)
        // An unknown key name is a type error.
        let bad = compiler.compile("""
        export default function route(link: Link) { return link.modifiers.includes("hyper") ? "Work" : undefined; }
        """, declarations: decls)
        #expect(bad.javascript == nil)
    }

    @Test func throwingScriptIsAnError() throws {
        let s = try script(#"export default function route(link: Link): ProfileName | undefined { throw new Error("nope"); }"#)
        guard case .error(let m) = s.route(web("https://a.com"), opener: nil) else { Issue.record("no error"); return }
        #expect(m.contains("nope"))
    }

    @Test func loopingScriptIsStoppedAndIsAnError() throws {
        try #require(ConfigScript.hasTimeLimit, "JSContextGroupSetExecutionTimeLimit not found")
        let s = try script("export default function route(link: Link): ProfileName | undefined { for (;;) {} }")
        let start = Date()
        #expect(s.route(web("https://a.com"), opener: nil) == .error("took too long"))
        #expect(Date().timeIntervalSince(start) < 2)
        // The context still works after a timeout.
        #expect(s.route(web("https://a.com"), opener: nil) == .error("took too long"))
    }

    @Test func nonStringResultIsAnError() throws {
        let s = try script("export default function route(link: Link): any { return 42; }")
        #expect(s.route(web("https://a.com"), opener: nil) == .error("route() must return a profile name, { browser, profile }, a list of them, or undefined"))
    }

    @Test func canNameABrowserAndProfile() throws {
        let s = try script("""
        export default function route(link: Link): Target | undefined {
          return { browser: "Brave", profile: "Work" };
        }
        """)
        #expect(s.route(web("https://a.com"), opener: nil) == .profile("Work", browser: "Brave"))
    }

    @Test func declarationsNameBrowsersAndATargetType() {
        #expect(decls.contains(#"type BrowserName = "Brave";"#))
        #expect(decls.contains(#"type OneTarget = ProfileName | { browser: BrowserName; profile: "Primary" | "Work" };"#))
        #expect(decls.contains(#"type Target = OneTarget | readonly (string | { browser?: string; profile: string })[];"#))
    }

    /// A list opens in the first profile this Mac has, so it may name
    /// profiles only another Mac has and still type-check.
    @Test func canReturnAListOfProfiles() throws {
        let s = try script("""
        export default function route(link: Link): Target | undefined {
          return [{ browser: "Dia", profile: "Primary" }, "Work", { profile: "Home" }];
        }
        """)
        #expect(s.route(web("https://a.com"), opener: nil)
                == .firstOf([ScriptTarget("Primary", browser: "Dia"), ScriptTarget("Work"), ScriptTarget("Home")]))
        let bad = try script("export default function route(link: Link): any { return [\"Work\", 3]; }")
        #expect(bad.route(web("https://a.com"), opener: nil)
                == .error("each entry of the list route() returns must be a profile name or { browser, profile }"))
    }

    @Test func missingDefaultExportIsRejected() {
        #expect(throws: ConfigError.noRouteFunction) { try script("export const x = 1;") }
    }

    @Test func scriptCannotReachTheSystem() throws {
        let s = try script("""
        export default function route(link: Link): any {
          const g: any = globalThis;
          return [typeof g.fetch, typeof g.require, typeof g.process, typeof g.XMLHttpRequest].join(",");
        }
        """)
        #expect(s.route(web("https://a.com"), opener: nil) == .profile("undefined,undefined,undefined,undefined"))
    }

    @Test func consoleLogGoesToTheLog() throws {
        final class Box: @unchecked Sendable { var lines: [String] = [] }
        let box = Box()
        let out = compiler.compile(#"export default function route(link: Link) { console.log("saw", link.host); return undefined; }"#,
                                   declarations: decls)
        let s = try ConfigScript(javascript: try #require(out.javascript), log: { box.lines.append($0) })
        _ = s.route(web("https://a.com"), opener: nil)
        #expect(box.lines == ["saw a.com"])
    }
}

@Suite(.serialized) struct ConfigLoaderTests {
    func tempPaths() throws -> SettingsFolder {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return SettingsFolder(directory: dir)
    }

    @Test func absentWhenThereIsNoConfig() throws {
        guard case .absent = ConfigLoader.load(paths: try tempPaths(), compiler: compiler, catalog: catalog) else {
            Issue.record("expected absent"); return
        }
    }

    @Test func loadsTheStarterConfig() throws {
        let p = try tempPaths()
        try ConfigLoader.starterConfig.write(to: p.configFile, atomically: true, encoding: .utf8)
        guard case .loaded(let s) = ConfigLoader.load(paths: p, compiler: compiler, catalog: catalog) else {
            Issue.record("expected loaded"); return
        }
        #expect(s.route(web("https://a.com"), opener: nil) == .noOpinion)
    }

    @Test func refusesAFileOthersCanWrite() throws {
        let p = try tempPaths()
        try ConfigLoader.starterConfig.write(to: p.configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: p.configFile.path)
        guard case .failed(.unsafeFile(let m)) = ConfigLoader.load(paths: p, compiler: compiler, catalog: catalog) else {
            Issue.record("expected refusal"); return
        }
        #expect(m.contains("other users"))
    }

    @Test func refusesAFolderOthersCanWrite() throws {
        let p = try tempPaths()
        try ConfigLoader.starterConfig.write(to: p.configFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: p.directory.path)
        #expect(FileSafety.problem(with: p.configFile)?.contains("folder") == true)
    }

    @Test func refusesAFileOwnedBySomeoneElse() throws {
        let p = try tempPaths()
        try ConfigLoader.starterConfig.write(to: p.configFile, atomically: true, encoding: .utf8)
        #expect(FileSafety.problem(with: p.configFile, uid: getuid() + 1)?.contains("not owned by you") == true)
    }

    /// Review round 1, F3: without a time limit, config.ts is not used.
    @Test func refusesToRunConfigWithoutATimeLimit() throws {
        let p = try tempPaths()
        try ConfigLoader.starterConfig.write(to: p.configFile, atomically: true, encoding: .utf8)
        guard case .failed(.engine(let m)) = ConfigLoader.load(paths: p, compiler: compiler, catalog: catalog,
                                                               timeLimitAvailable: false) else {
            Issue.record("expected refusal"); return
        }
        #expect(m.contains("time limit"))
    }

    @Test func reportsTypeErrors() throws {
        let p = try tempPaths()
        try "export default function route(link: Link): ProfileName | undefined { return 1; }"
            .write(to: p.configFile, atomically: true, encoding: .utf8)
        guard case .failed(.compile(let errs)) = ConfigLoader.load(paths: p, compiler: compiler, catalog: catalog) else {
            Issue.record("expected type error"); return
        }
        #expect(errs.first?.hasPrefix("config.ts:1:") == true)
    }

    /// `betterlink test` says when config.ts doesn't load, instead of
    /// quietly testing without it.
    @Test func agentTestReportsABrokenConfig() throws {
        let p = try tempPaths()
        try RuleStore(folder: p).save(RuleStore.Contents())
        try "export default function route(link: Link): ProfileName | undefined { return 1; }"
            .write(to: p.configFile, atomically: true, encoding: .utf8)
        let env = AgentEnvironment(folder: p, installed: [Browser.brave], compiler: compiler)
        let out = Agent.run("test", input: ["link": "https://a.com/"], env: env).json()
        let data = (try JSONSerialization.jsonObject(with: out) as? [String: Any])?["data"] as? [String: Any]
        #expect((data?["configError"] as? String)?.isEmpty == false)
        #expect(data?["note"] != nil)
    }

    @Test func editorSupportFilesTypeCheckTheStarter() throws {
        let p = try tempPaths()
        try ConfigLoader.writeEditorSupport(paths: p, catalog: catalog)
        let d = try String(contentsOf: p.declarationsFile, encoding: .utf8)
        #expect(d.contains(#"type ProfileName = "Primary" | "Work";"#))
        #expect(compiler.compile(ConfigLoader.starterConfig, declarations: d).errors.isEmpty)
    }
}
