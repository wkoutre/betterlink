import Foundation
import JavaScriptCore

/// Type-checks and compiles config.ts with the TypeScript compiler bundled in
/// the app (TypeScript 6.0.3, the last release written in JavaScript), run in
/// JavaScriptCore. Nothing on the Mac needs to be installed, and no process is
/// started.
public final class TypeScriptCompiler: @unchecked Sendable {
    public struct Output: Equatable, Sendable {
        /// Compiled JavaScript, present only when there were no errors.
        public let javascript: String?
        /// Type errors and syntax errors, as "config.ts:3:5 message".
        public let errors: [String]
    }

    private let context: JSContext
    private let libs: [String: String]
    private let lock = NSLock()

    /// - Parameters:
    ///   - typescriptJS: `typescript.js` from the TypeScript package.
    ///   - libDirectory: the package's `lib` folder with `lib.*.d.ts`.
    public init(typescriptJS: URL, libDirectory: URL) throws {
        guard let ctx = JSContext() else { throw ConfigError.engine("could not start JavaScriptCore") }
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        ctx.evaluateScript(try String(contentsOf: typescriptJS, encoding: .utf8))
        ctx.evaluateScript(Self.harness)
        if let thrown { throw ConfigError.engine("TypeScript failed to load: \(thrown)") }
        context = ctx
        libs = try Self.loadLibs(root: "lib.es2020.d.ts", dir: libDirectory)
    }

    public func compile(_ source: String, declarations: String) -> Output {
        lock.lock(); defer { lock.unlock() }
        let files = ["config.ts": source, "betterlink.d.ts": declarations]
        guard let r = context.objectForKeyedSubscript("__betterlinkCompile").call(withArguments: [files, libs]),
              let json = r.toString(), let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Output(javascript: nil, errors: ["the TypeScript compiler failed"]) }
        let errors = (obj["errors"] as? [String]) ?? ["the TypeScript compiler failed"]
        return Output(javascript: errors.isEmpty ? obj["js"] as? String : nil, errors: errors)
    }

    /// lib.es2020.d.ts and every lib it references.
    private static func loadLibs(root: String, dir: URL) throws -> [String: String] {
        var libs: [String: String] = [:]
        var queue = [root]
        let re = try NSRegularExpression(pattern: #"/// <reference lib="([^"]+)""#)
        while let name = queue.popLast() {
            if libs[name] != nil { continue }
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            libs[name] = text
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                queue.append("lib." + (text as NSString).substring(with: m.range(at: 1)) + ".d.ts")
            }
        }
        return libs
    }

    /// An in-memory compiler host: the compiler sees only config.ts,
    /// betterlink.d.ts and the standard library, never the file system.
    private static let harness = #"""
    var __betterlinkCompile = function (files, libs) {
      var options = { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, strict: true,
                      lib: ["lib.es2020.d.ts"], types: [], noEmit: true };
      var all = {};
      Object.keys(libs).forEach(function (k) { all["/lib/" + k] = libs[k]; });
      Object.keys(files).forEach(function (k) { all["/" + k] = files[k]; });
      var host = {
        getSourceFile: function (n, v) { return all[n] === undefined ? undefined : ts.createSourceFile(n, all[n], v); },
        getDefaultLibFileName: function () { return "/lib/lib.es2020.d.ts"; },
        getDefaultLibLocation: function () { return "/lib"; },
        writeFile: function () {}, getCurrentDirectory: function () { return "/"; },
        getDirectories: function () { return []; }, fileExists: function (n) { return all[n] !== undefined; },
        readFile: function (n) { return all[n]; }, getCanonicalFileName: function (n) { return n; },
        useCaseSensitiveFileNames: function () { return true; }, getNewLine: function () { return "\n"; }
      };
      var program = ts.createProgram(["/config.ts", "/betterlink.d.ts"], options, host);
      var errors = ts.getPreEmitDiagnostics(program).map(function (d) {
        var msg = ts.flattenDiagnosticMessageText(d.messageText, "\n");
        if (!d.file) return msg;
        var p = d.file.getLineAndCharacterOfPosition(d.start);
        return d.file.fileName.slice(1) + ":" + (p.line + 1) + ":" + (p.character + 1) + " " + msg;
      });
      var js = errors.length ? "" : ts.transpileModule(files["config.ts"], { compilerOptions:
        { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
      return JSON.stringify({ errors: errors, js: js });
    };
    """#
}

public enum ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    case engine(String)
    case unsafeFile(String)
    case compile([String])
    case noRouteFunction

    public var description: String {
        switch self {
        case .engine(let m): m
        case .unsafeFile(let m): m
        case .compile(let errs): errs.joined(separator: "\n")
        case .noRouteFunction: "config.ts must `export default function route(link: Link)`."
        }
    }
}

/// Compiled config.ts, ready to route links. Runs in its own JavaScriptCore
/// context with no file, network or process access, and a time limit on each
/// call, so a slow or looping script sends the link to the fallback profile.
public final class ConfigScript: LinkScript, @unchecked Sendable {
    private let context: JSContext
    private let route: JSValue
    private let lock = NSLock()

    public init(javascript: String, timeLimit: TimeInterval = 0.25, log: (@Sendable (String) -> Void)? = nil) throws {
        let group = JSContextGroupCreate()
        defer { JSContextGroupRelease(group) }
        let global = JSGlobalContextCreateInGroup(group, nil)
        defer { JSGlobalContextRelease(global) }
        let ctx = JSContext(jsGlobalContextRef: global!)!
        if let setLimit = Self.setTimeLimit { setLimit(group, timeLimit, nil, nil) }
        var thrown: String?
        ctx.exceptionHandler = { _, e in thrown = e?.toString() }
        let console: @convention(block) () -> Void = {
            let parts = (JSContext.currentArguments() as? [JSValue] ?? []).map { $0.toString() ?? "" }
            log?(parts.joined(separator: " "))
        }
        let consoleObj = JSValue(newObjectIn: ctx)!
        consoleObj.setObject(console, forKeyedSubscript: "log" as NSString)
        ctx.setObject(consoleObj, forKeyedSubscript: "console" as NSString)
        let exports = ctx.evaluateScript("(function(){ var exports = {}; var module = { exports: exports };\n"
                                         + javascript + "\n; return module.exports; })()")
        if let thrown { throw ConfigError.compile(["config.ts threw while loading: \(thrown)"]) }
        guard let fn = exports?.objectForKeyedSubscript("default"), fn.isObject,
              ctx.evaluateScript("(function(f){ return typeof f === 'function'; })")?.call(withArguments: [fn])?.toBool() == true
        else { throw ConfigError.noRouteFunction }
        context = ctx
        route = fn
    }

    public func route(_ link: Link, opener: String?, modifiers: ModifierKeys) -> ScriptVerdict {
        lock.lock(); defer { lock.unlock() }
        var thrown: String?
        context.exceptionHandler = { _, e in thrown = e?.toString() ?? "error" }
        let arg: [String: Any] = [
            "href": link.href, "scheme": link.scheme, "host": link.host,
            "port": link.port.map { $0 as Any } ?? NSNull(),
            "path": link.path, "query": link.query ?? "", "fragment": link.fragment ?? "",
            "opener": opener ?? "",
            "modifiers": modifiers.names,
        ]
        let result = route.call(withArguments: [arg])
        if let thrown {
            return .error(thrown.contains("JavaScript execution terminated") || thrown.contains("Execution timed out")
                          ? "took too long" : thrown)
        }
        guard let result, !result.isUndefined, !result.isNull else { return .noOpinion }
        if result.isString, let name = result.toString() { return .profile(name) }
        // { browser: "Google Chrome", profile: "Work" }
        if result.isObject, let profile = result.objectForKeyedSubscript("profile"), profile.isString,
           let browser = result.objectForKeyedSubscript("browser"), browser.isString || browser.isUndefined {
            return .profile(profile.toString(), browser: browser.isUndefined ? nil : browser.toString())
        }
        return .error("route() must return a profile name, { browser, profile }, or undefined")
    }

    /// JavaScriptCore's per-context-group execution time limit. Exported by
    /// the framework but declared only in a private header, so it is looked up
    /// at run time. Without it there is no time limit.
    private typealias SetLimitFn = @convention(c) (JSContextGroupRef?, Double, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void
    private static let setTimeLimit: SetLimitFn? = {
        guard let h = dlopen("/System/Library/Frameworks/JavaScriptCore.framework/JavaScriptCore", RTLD_NOW),
              let sym = dlsym(h, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(sym, to: SetLimitFn.self)
    }()
    public static var hasTimeLimit: Bool { setTimeLimit != nil }
}

/// The type declarations config.ts is checked against, with the browser's
/// real profile names. betterlink also writes this file next to config.ts so
/// an editor can autocomplete it.
public func configDeclarations(catalog: ProfileCatalog) -> String {
    func lit(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    func union(_ xs: [String]) -> String {
        let u = Array(NSOrderedSet(array: xs)) as? [String] ?? xs
        return u.isEmpty ? "string" : u.map(lit).joined(separator: " | ")
    }
    // A name more than one profile uses is left out, so returning it bare
    // fails the type check; { browser, profile } still accepts it.
    // Safari and Arc are always listed but aren't profiles to choose; with no
    // real profiles, any name type-checks.
    let shared = catalog.repeatedNames
    let real = catalog.profiles.filter { !$0.directory.isEmpty }
    let unique = catalog.profiles.map(\.name).filter { !shared.contains($0) }
    let profileNames = real.isEmpty ? "string" : unique.isEmpty ? "never" : union(unique)
    let browsers = catalog.profiles.compactMap { Browser.known(bundleId: $0.browser)?.name }
    return """
    // Written by betterlink. Do not edit: it is rewritten when profiles change.

    /** A profile name, exactly as betterlink shows it. Names that more than
     *  one profile uses are left out: if they are in different browsers,
     *  return { browser, profile } instead; if they are in the same browser,
     *  rename one in that browser (or, without browser data access, in
     *  betterlink's Profiles). */
    type ProfileName = \(profileNames);

    /** A browser, as betterlink names it. */
    type BrowserName = \(union(browsers));

    /** Where to open a link: a profile name, or a profile in one browser. */
    type Target = ProfileName | { browser: BrowserName; profile: \(union(catalog.profiles.map(\.name))) };

    /** The link being opened, parsed the way the browser parses it. */
    interface Link {
      /** The full link that will open, e.g. "https://app.acme.com/swap?x=1". */
      readonly href: string;
      /** "http" or "https". */
      readonly scheme: string;
      /** Lowercase host, e.g. "app.acme.com". */
      readonly host: string;
      /** The port when it is not the scheme's default, otherwise null. */
      readonly port: number | null;
      /** Starts with "/". */
      readonly path: string;
      /** Without the "?"; "" when there is none. */
      readonly query: string;
      /** Without the "#"; "" when there is none. */
      readonly fragment: string;
      /** Bundle id of the app the link came from, e.g. "com.tinyspeck.slackmacgap"; "" if unknown. */
      readonly opener: string;
      /** Modifier keys held when the link was clicked, e.g. ["control", "command"]; [] when none.
       *  A Modifier Keys rule for exactly these keys runs before config.ts, so it never sees them. */
      readonly modifiers: readonly ("control" | "option" | "shift" | "command")[];
    }

    /** Writes to betterlink's log view. Nothing else is available: no fetch, files or timers. */
    declare const console: { log(...values: unknown[]): void };

    """
}
