import Foundation

/// What an agent command needs to know about this Mac.
public struct AgentEnvironment: Sendable {
    public let folder: SettingsFolder
    /// Browsers betterlink knows that are installed.
    public let installed: [Browser]
    /// The bundled TypeScript compiler, for config.check. Nil when unavailable.
    public let compiler: TypeScriptCompiler?
    /// Whether this Mac draws a built-in symbol by that name. The app passes
    /// AppKit's answer; nil (tests, no AppKit) checks the name's shape only.
    public let symbolExists: (@Sendable (String) -> Bool)?

    public init(folder: SettingsFolder, installed: [Browser], compiler: TypeScriptCompiler? = nil,
                symbolExists: (@Sendable (String) -> Bool)? = nil) {
        self.folder = folder; self.installed = installed; self.compiler = compiler; self.symbolExists = symbolExists
    }
}

/// One answer to one agent command: `{"version":1,"ok":true,"data":…}` or
/// `{"version":1,"ok":false,"error":"…"}`.
public struct AgentResponse {
    public let ok: Bool
    public let data: Any?
    public let error: String?

    static func success(_ data: Any? = nil) -> AgentResponse { AgentResponse(ok: true, data: data, error: nil) }
    static func failure(_ message: String) -> AgentResponse { AgentResponse(ok: false, data: nil, error: message) }

    public func json() -> Data {
        var obj: [String: Any] = ["version": 1, "ok": ok]
        if let data { obj["data"] = data }
        if let error { obj["error"] = error }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data(#"{"version":1,"ok":false,"error":"encoding failed"}"#.utf8)
    }
}

/// The commands behind the betterlink CLI. Everything the window can change
/// is here, checked by the same code the app routes with, and written
/// through RuleStore's lock so the app and an agent never lose each
/// other's changes. The app's log is in its memory only, so it isn't here.
///
/// A few commands need the app itself (default browser, open at login);
/// those live in the app target, not here.
public enum Agent {
    public static let commands: [String] = [
        "status", "browsers.list",
        "rules.list", "rules.profiles", "rules.add", "rules.update", "rules.remove", "rules.move", "rules.name",
        "keys.list", "keys.add", "keys.update", "keys.remove",
        "fallback.get", "fallback.set",
        "profiles.list", "profiles.add", "profiles.update", "profiles.remove", "profiles.import",
        "settings.get", "settings.set",
        "config.path", "config.init", "config.check",
        "test",
    ] + sidebarCommands + syncCommands

    public static func run(_ command: String, input: [String: Any], env: AgentEnvironment) -> AgentResponse {
        do {
            switch command {
            case "status": return try status(env)
            case "browsers.list": return .success(env.installed.map(describe))
            case "rules.list": return try .success(rulesList(input, env))
            case "rules.profiles": return try .success(rulesProfiles(env))
            case "rules.add": return try rulesAdd(input, env)
            case "rules.update": return try rulesUpdate(input, env)
            case "rules.remove": return try rulesRemove(input, env)
            case "rules.move": return try rulesMove(input, env)
            case "rules.name": return try rulesName(input, env)
            case "keys.list": return try .success(keysList(env))
            case "keys.add": return try keysAdd(input, env)
            case "keys.update": return try keysUpdate(input, env)
            case "keys.remove": return try keysRemove(input, env)
            case "fallback.get": return try fallbackGet(env)
            case "fallback.set": return try fallbackSet(input, env)
            case "profiles.list": return try .success(catalog(env).profiles.map(describe))
            case "profiles.add": return try profilesAdd(input, env)
            case "profiles.update": return try profilesUpdate(input, env)
            case "profiles.remove": return try profilesRemove(input, env)
            case "profiles.import": return try profilesImport(env)
            case "settings.get": return try settingsGet(env)
            case "settings.set": return try settingsSet(input, env)
            case "config.path": return .success(["path": env.folder.configFile.path, "exists": FileManager.default.fileExists(atPath: env.folder.configFile.path)])
            case "config.init": return try configInit(env)
            case "config.check": return configCheck(env)
            case "test": return try test(input, env)
            default:
                if let r = try sidebarRun(command, input, env) { return r }
                if let r = try syncRun(command, input, env) { return r }
                return .failure("Unknown command \(command). Commands: \(commands.joined(separator: ", ")).")
            }
        } catch let e as AgentError {
            return .failure(e.message)
        } catch {
            return .failure("\(error)")
        }
    }

    struct AgentError: Error { let message: String }
    static func fail(_ m: String) -> AgentError { AgentError(message: m) }

    // MARK: Helpers

    private static func store(_ env: AgentEnvironment) -> RuleStore { RuleStore(folder: env.folder) }

    private static func catalog(_ env: AgentEnvironment, _ contents: RuleStore.Contents? = nil) throws -> ProfileCatalog {
        let c = try contents ?? store(env).load()
        return ProfileCatalog(profiles: c.profiles ?? []).addingPlain(installed: env.installed)
    }

    // Inputs are checked for type, never coerced: a position of 1.5 or a
    // showLog of 1 is refused, because rule order and settings decide routing.

    static func string(_ input: [String: Any], _ key: String) throws -> String? {
        guard let v = input[key], !(v is NSNull) else { return nil }
        guard let s = v as? String else { throw fail("\(key) must be text.") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A list position, counted from 1. Refuses 0 and below (the smallest
    /// Int would overflow `position - 1`).
    static func position(_ input: [String: Any], _ key: String) throws -> Int? {
        guard let n = try int(input, key) else { return nil }
        guard n >= 1 else { throw fail("\(key) must be 1 or more.") }
        return n
    }

    static func int(_ input: [String: Any], _ key: String) throws -> Int? {
        guard let v = input[key], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n),
              // Int(exactly:) is nil for a value Int can't hold, instead of wrapping it.
              let i = Int(exactly: n) else {
            throw fail("\(key) must be a whole number.")
        }
        return i
    }

    static func bool(_ input: [String: Any], _ key: String) throws -> Bool? {
        guard let v = input[key], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw fail("\(key) must be true or false.") }
        return n.boolValue
    }

    private static func describe(_ b: Browser) -> [String: Any] {
        ["name": b.name, "bundleId": b.bundleId, "family": b.family.rawValue]
    }

    private static func hex(_ c: UInt32?) -> Any { c.map { String(format: "#%06X", $0) } ?? NSNull() }

    private static func describe(_ p: BrowserProfile) -> [String: Any] {
        ["browser": p.browser, "browserName": Browser.known(bundleId: p.browser)?.name ?? p.browser,
         "directory": p.directory, "name": p.name, "color": hex(p.color)]
    }

    /// A browser by name ("Google Chrome") or bundle id.
    private static func browser(named s: String) -> Browser? {
        Browser.known.first { $0.bundleId == s || $0.name.caseInsensitiveCompare(s) == .orderedSame }
    }

    /// Whether this Mac has the profile: listed, in an installed browser. The
    /// first of a rule's profiles that it has is where the rule opens links.
    private static func has(_ cat: ProfileCatalog, _ env: AgentEnvironment) -> (ProfileRef) -> Bool {
        let installed = Set(env.installed.map(\.bundleId))
        return { cat.profile($0) != nil && installed.contains($0.browser) }
    }

    /// A rule's other profiles, from `then`: a list of "Profile" or
    /// "Browser:Profile" (as `--profile` and `--browser` name them). nil when
    /// `then` wasn't given; an empty list removes them.
    private static func backups(_ input: [String: Any], in cat: ProfileCatalog) throws -> [ProfileRef]? {
        guard let v = input["then"], !(v is NSNull) else { return nil }
        guard let list = v as? [Any] else { throw fail("then must be a list of profiles.") }
        return try list.map { item -> ProfileRef in
            guard let raw = (item as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
                throw fail("Each then must be a profile name, or Browser:Profile.")
            }
            // "Brave:Work" names a browser only when the part before ":" is one.
            if let colon = raw.firstIndex(of: ":"), browser(named: String(raw[..<colon]).trimmingCharacters(in: .whitespaces)) != nil {
                return try resolveProfile(browser: String(raw[..<colon]).trimmingCharacters(in: .whitespaces),
                                          profile: String(raw[raw.index(after: colon)...]).trimmingCharacters(in: .whitespaces), in: cat).ref
            }
            return try resolveProfile(browser: nil, profile: raw, in: cat).ref
        }
    }

    /// A profile by name or folder, within a browser when one is given.
    private static func resolveProfile(browser b: String?, profile: String?, in cat: ProfileCatalog) throws -> BrowserProfile {
        guard let profile, !profile.isEmpty else { throw fail("Missing profile: give a profile name or folder, and optionally a browser.") }
        var candidates = cat.profiles
        if let b, !b.isEmpty {
            guard let br = browser(named: b) else { throw fail("Unknown browser \"\(b)\". See browsers.list.") }
            candidates = candidates.filter { $0.browser == br.bundleId }
        }
        let matches = candidates.filter { $0.name == profile || ($0.directory == profile && !profile.isEmpty) }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty { throw fail("No profile \"\(profile)\"\(b.map { " in \($0)" } ?? ""). See profiles.list.") }
        throw fail("More than one profile matches \"\(profile)\"; give the browser too.")
    }

    // MARK: Status

    private static func status(_ env: AgentEnvironment) throws -> AgentResponse {
        let c = try store(env).load()
        return .success([
            "settingsFolder": env.folder.directory.path,
            "rules": c.rules.count,
            "keyRules": (c.modifierRules ?? []).count,
            "profiles": (c.profiles ?? []).count,
            "fallback": try fallbackDescription(c, env),
            "config": FileManager.default.fileExists(atPath: env.folder.configFile.path) ? "present" : "absent",
            "installedBrowsers": env.installed.map(\.name),
        ])
    }

    // MARK: Rules

    /// Every rule in the order they are checked, or one profile's rules
    /// (still numbered by their place in the full list). Each rule says
    /// which rules for other profiles can take the same links: `checkedAfter`
    /// lists rules above it, `checkedBefore` rules below it, and `hiddenBy`
    /// names the first rule above that takes the very link it is written for.
    private static func rulesList(_ input: [String: Any], _ env: AgentEnvironment) throws -> [[String: Any]] {
        let c = try store(env).load()
        let cat = try catalog(env, c)
        var only: ProfileRef?
        if let name = try string(input, "profile") {
            only = try resolveProfile(browser: try string(input, "browser"), profile: name, in: cat).ref
        } else if try string(input, "browser") != nil {
            throw fail("--browser narrows --profile: give a profile too.")
        }
        let key = RuleGroups.opensIn(has(cat, env))
        let crossings = RuleGroups.crossings(c.rules, key: key)
        // Synced rules whose profile this Mac lacks (the last sync's notes).
        let syncNotes = SyncLocalStore(folder: env.folder).load()
        let unresolved = Set(syncNotes.unresolvedRules ?? [])
        let madeFor = syncNotes.missingProfiles ?? [:]
        func brief(_ i: Int) -> [String: Any] {
            let r = c.rules[i]
            let k = key(r)
            return ["id": r.id.uuidString, "position": i + 1, "pattern": r.pattern,
                    "profile": k.directory, "profileName": cat.profile(k)?.name ?? NSNull()]
        }
        func target(_ ref: ProfileRef) -> [String: Any] {
            ["browser": ref.browser, "browserName": Browser.known(bundleId: ref.browser)?.name ?? ref.browser,
             "profile": ref.directory, "profileName": cat.profile(ref)?.name ?? NSNull()]
        }
        let here = has(cat, env)
        return c.rules.enumerated().compactMap { i, r -> [String: Any]? in
            if let only, key(r) != only { return nil }
            let p = cat.profile(r.target)
            let above = crossings.filter { $0.later == i }, below = crossings.filter { $0.earlier == i }
            return ["id": r.id.uuidString, "position": i + 1, "kind": r.kind.rawValue, "kindLabel": r.kind.label,
                    "pattern": r.pattern, "browser": r.browser,
                    "browserName": Browser.known(bundleId: r.browser)?.name ?? r.browser,
                    "profile": r.profile, "profileName": p?.name ?? NSNull(), "problem": r.problem ?? NSNull(),
                    "backups": r.backups.map(target),
                    "opensIn": r.opensIn(here).map(target) ?? NSNull(),
                    "unresolved": unresolved.contains(r.id),
                    "madeFor": unresolved.contains(r.id) ? (madeFor[r.id.uuidString] ?? NSNull()) : NSNull(),
                    "hiddenBy": above.first(where: \.hidesLater).map { x -> Any in
                        var b = brief(x.earlier); b["example"] = x.example; return b
                    } ?? NSNull(),
                    "checkedAfter": above.map { brief($0.earlier) },
                    "checkedBefore": below.map { brief($0.later) }]
        }
    }

    /// The profiles that have rules, as the Link Rules page lists them:
    /// how many rules each has, where they sit, and how many of them a
    /// rule for another profile hides.
    private static func rulesProfiles(_ env: AgentEnvironment) throws -> [[String: Any]] {
        let c = try store(env).load()
        let cat = try catalog(env, c)
        let key = RuleGroups.opensIn(has(cat, env))
        let hidden = Set(RuleGroups.crossings(c.rules, key: key).filter(\.hidesLater).map(\.later))
        return RuleGroups.groups(c.rules, order: cat.profiles.map(\.ref), key: key).map { g -> [String: Any] in
            let p = cat.profile(g.target)
            return ["browser": g.target.browser,
                    "browserName": Browser.known(bundleId: g.target.browser)?.name ?? g.target.browser,
                    "profile": g.target.directory, "profileName": p?.name ?? NSNull(), "color": hex(p?.color),
                    "name": c.groupName(g.target) ?? NSNull(),
                    "rules": g.positions.count, "positions": g.positions.map { $0 + 1 },
                    "hidden": g.positions.filter(hidden.contains).count]
        }
    }

    private static func kind(_ s: String?) throws -> Rule.Kind {
        guard let s, let k = Rule.Kind(rawValue: s) else {
            throw fail("Unknown kind \"\(s ?? "")\": use domain, startsWith or contains.")
        }
        return k
    }

    private static func rulesAdd(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        let k = try kind(try string(input, "kind"))
        let pattern = try string(input, "pattern") ?? ""
        var added: Rule?
        try store(env).update { c in
            let cat = try catalog(env, c)
            let p = try resolveProfile(browser: try string(input, "browser"), profile: try string(input, "profile"), in: cat)
            var rule = Rule(kind: k, pattern: pattern, browser: p.browser, profile: p.directory)
            if let more = try backups(input, in: cat) { rule.setTargets([p.ref] + more) }
            if let problem = rule.problem { throw fail("Not added: \(problem) (kind \(k.rawValue), domain or link pattern).") }
            let at = try position(input, "position").map { max(0, min($0 - 1, c.rules.count)) } ?? c.rules.count
            c.rules.insert(rule, at: at)
            added = rule
        }
        return .success(["id": added!.id.uuidString])
    }

    private static func ruleIndex(_ input: [String: Any], _ c: RuleStore.Contents) throws -> Int {
        guard let id = try string(input, "id"), let i = c.rules.firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame })
        else { throw fail("No rule with id \"\(try string(input, "id") ?? "")\". See rules.list.") }
        return i
    }

    private static func rulesUpdate(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try store(env).update { c in
            let i = try ruleIndex(input, c)
            var r = c.rules[i]
            if let k = try string(input, "kind") { r.kind = try kind(k) }
            if let p = try string(input, "pattern") { r.pattern = p }
            let newProfile = try string(input, "profile"), newBrowser = try string(input, "browser")
            if newProfile != nil || newBrowser != nil {
                let p = try resolveProfile(browser: newBrowser ?? Browser.known(bundleId: r.browser)?.name,
                                           profile: newProfile ?? r.profile, in: try catalog(env, c))
                r.browser = p.browser; r.profile = p.directory
            }
            if let more = try backups(input, in: try catalog(env, c)) { r.setTargets([r.target] + more) }
            else { r.setTargets(r.targets) }
            if let problem = r.problem { throw fail("Not updated: \(problem)") }
            c.rules[i] = r
        }
        return .success()
    }

    private static func rulesRemove(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try store(env).update { c in c.rules.remove(at: try ruleIndex(input, c)) }
        return .success()
    }

    private static func rulesMove(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard let to = try position(input, "to") else { throw fail("Missing \"to\": the new position, starting at 1.") }
        try store(env).update { c in
            let i = try ruleIndex(input, c)
            let r = c.rules.remove(at: i)
            c.rules.insert(r, at: max(0, min(to - 1, c.rules.count)))
        }
        return .success()
    }

    /// Names a profile's group on the Link Rules page; an empty name removes
    /// it. The profile may be one only another Mac has (a synced rule's), so
    /// besides the profile list it matches the folders rules name, and a
    /// group's current name.
    private static func rulesName(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard let name = try string(input, "name") else { throw fail("Missing name: the group's new name, or \"\" to remove it.") }
        guard let profile = try string(input, "profile"), !profile.isEmpty else {
            throw fail("Missing profile: give the profile name or folder, as rules profiles lists it.")
        }
        var named: ProfileRef?
        try store(env).update { c in
            let cat = try catalog(env, c)
            var only: String?
            if let b = try string(input, "browser"), !b.isEmpty {
                guard let br = browser(named: b) else { throw fail("Unknown browser \"\(b)\". See browsers.list.") }
                only = br.bundleId
            }
            var refs: [ProfileRef] = []
            for ref in cat.profiles.map(\.ref) + c.rules.flatMap(\.targets) where !refs.contains(ref) && (only == nil || ref.browser == only) {
                refs.append(ref)
            }
            let matches = refs.filter { ref in
                cat.profile(ref)?.name == profile || ref.directory == profile || c.groupName(ref) == profile
            }
            guard let ref = matches.first else {
                throw fail("No profile \"\(profile)\"\(only.map { " in \(Browser.known(bundleId: $0)?.name ?? $0)" } ?? ""). See rules profiles.")
            }
            if matches.count > 1 { throw fail("More than one profile matches \"\(profile)\"; give the browser too.") }
            c.setGroupName(name, for: ref)
            named = ref
        }
        return .success(["browser": named!.browser, "profile": named!.directory,
                         "name": name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : name.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    // MARK: Modifier keys

    /// "control,command", "ctrl+cmd", "⌃⌘", or ["control", "command"].
    private static func modifierKeys(_ input: [String: Any], _ key: String) throws -> ModifierKeys? {
        guard let v = input[key], !(v is NSNull) else { return nil }
        let names: [String]
        if let list = v as? [Any] {
            guard let strings = list as? [String] else { throw fail("\(key) must be key names, such as control,command.") }
            names = strings
        } else if let s = v as? String {
            // Split names on , + - and spaces; symbols may also run together ("⌃⌘").
            let symbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
            names = s.split(whereSeparator: { ",+- ".contains($0) })
                .flatMap { part -> [String] in
                    part.allSatisfy { symbols.contains($0) } ? part.map { String($0) } : [String(part)]
                }
        } else {
            throw fail("\(key) must be key names, such as control,command.")
        }
        guard let keys = ModifierKeys(names: names) else {
            throw fail("Unknown key in \(key): use control, option, shift and command (or ctrl, alt, cmd).")
        }
        return keys
    }

    private static func keysList(_ env: AgentEnvironment) throws -> [[String: Any]] {
        let c = try store(env).load()
        let cat = try catalog(env, c)
        let list = c.modifierRules ?? []
        let problems = ModifierRule.problems(in: list)
        return list.enumerated().map { i, r in
            ["id": r.id.uuidString, "position": i + 1, "keys": r.keys.names, "symbols": r.keys.symbols,
             "browser": r.browser, "browserName": Browser.known(bundleId: r.browser)?.name ?? r.browser,
             "profile": r.profile, "profileName": cat.profile(r.target)?.name ?? NSNull(),
             "problem": problems[i] ?? NSNull()]
        }
    }

    private static func checkKeys(_ list: [ModifierRule], verb: String) throws {
        let problems = ModifierRule.problems(in: list)
        if let first = problems.keys.min(), let problem = problems[first] {
            throw fail("\(verb): \(problem)")
        }
    }

    private static func keysAdd(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard let keys = try modifierKeys(input, "keys") else { throw fail("Missing keys, such as control,command.") }
        var added: ModifierRule?
        try store(env).update { c in
            let p = try resolveProfile(browser: try string(input, "browser"), profile: try string(input, "profile"), in: try catalog(env, c))
            let rule = ModifierRule(keys: keys, browser: p.browser, profile: p.directory)
            let next = (c.modifierRules ?? []) + [rule]
            try checkKeys(next, verb: "Not added")
            c.modifierRules = next
            added = rule
        }
        return .success(["id": added!.id.uuidString])
    }

    private static func keyRuleIndex(_ input: [String: Any], _ c: RuleStore.Contents) throws -> Int {
        guard let id = try string(input, "id"),
              let i = (c.modifierRules ?? []).firstIndex(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame })
        else { throw fail("No modifier key rule with id \"\(try string(input, "id") ?? "")\". See keys.list.") }
        return i
    }

    private static func keysUpdate(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try store(env).update { c in
            var list = c.modifierRules ?? []
            let i = try keyRuleIndex(input, c)
            var r = list[i]
            if let keys = try modifierKeys(input, "keys") { r.keys = keys }
            let newProfile = try string(input, "profile"), newBrowser = try string(input, "browser")
            if newProfile != nil || newBrowser != nil {
                let p = try resolveProfile(browser: newBrowser ?? Browser.known(bundleId: r.browser)?.name,
                                           profile: newProfile ?? r.profile, in: try catalog(env, c))
                r.browser = p.browser; r.profile = p.directory
            }
            list[i] = r
            try checkKeys(list, verb: "Not updated")
            c.modifierRules = list
        }
        return .success()
    }

    private static func keysRemove(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try store(env).update { c in
            let i = try keyRuleIndex(input, c)
            c.modifierRules?.remove(at: i)
        }
        return .success()
    }

    // MARK: Fallback

    /// Where links go when nothing is set: the first installed Chromium
    /// browser's default profile, else Safari. The app uses the same rule.
    public static func defaultFallback(installed: [Browser]) -> ProfileRef {
        if let b = installed.first(where: { $0.family == .chromium }) { return ProfileRef(browser: b.bundleId, directory: "Default") }
        if let s = installed.first(where: { $0.family == .plain }) { return ProfileRef(browser: s.bundleId, directory: "") }
        return ProfileRef(browser: Browser.brave.bundleId, directory: "Default")
    }

    /// The fallback to use on this Mac: the stored one when its browser is
    /// installed, else the default. A synced settings folder can name a
    /// browser another Mac doesn't have; links must still open.
    public static func effectiveFallback(_ stored: ProfileRef?, installed: [Browser]) -> ProfileRef {
        if let stored, installed.contains(where: { $0.bundleId == stored.browser }) { return stored }
        return defaultFallback(installed: installed)
    }

    private static func fallbackDescription(_ c: RuleStore.Contents, _ env: AgentEnvironment) throws -> [String: Any] {
        let ref = effectiveFallback(c.fallback, installed: env.installed)
        let p = try catalog(env, c).profile(ref)
        var d: [String: Any] = ["browser": ref.browser, "browserName": Browser.known(bundleId: ref.browser)?.name ?? ref.browser,
                                "directory": ref.directory, "name": p?.name ?? NSNull(), "isDefault": c.fallback == nil,
                                "replaced": c.fallback != nil && c.fallback != ref]
        if let stored = c.fallback, stored != ref {
            // rules.json names a browser this Mac doesn't have (a synced folder).
            d["stored"] = ["browser": stored.browser, "directory": stored.directory]
        }
        return d
    }

    private static func fallbackGet(_ env: AgentEnvironment) throws -> AgentResponse {
        .success(try fallbackDescription(try store(env).load(), env))
    }

    private static func fallbackSet(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try store(env).update { c in
            let p = try resolveProfile(browser: try string(input, "browser"), profile: try string(input, "profile"), in: try catalog(env, c))
            c.fallback = p.ref
        }
        return .success()
    }

    // MARK: Profiles

    private static func color(_ s: String?) throws -> UInt32? {
        guard let s, !s.isEmpty else { return nil }
        let h = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard h.count == 6, let v = UInt32(h, radix: 16) else { throw fail("Colour must look like #5B8DEF.") }
        return v
    }

    private static func validate(_ profiles: [BrowserProfile]) throws {
        for p in profiles {
            guard let b = Browser.known(bundleId: p.browser) else { throw fail("Unknown browser \(p.browser).") }
            if b.family == .plain { throw fail("\(b.name) has no profiles to add; it is listed automatically.") }
            if p.name.isEmpty { throw fail("Give the profile a name.") }
            if !BrowserProfile.isValid(directory: p.directory, family: b.family) {
                throw fail(b.family == .chromium ? "The folder must be \"Default\" or \"Profile\" and a number (see chrome://version)."
                                                 : "Give the Firefox profile's name; it can't start with \"-\".")
            }
        }
        for (i, p) in profiles.enumerated() {
            if profiles[..<i].contains(where: { $0.browser == p.browser && $0.directory == p.directory }) {
                throw fail("\(Browser.known(bundleId: p.browser)?.name ?? p.browser) already has \(p.directory).")
            }
            if profiles[..<i].contains(where: { $0.browser == p.browser && $0.name == p.name }) {
                throw fail("Two \(Browser.known(bundleId: p.browser)?.name ?? p.browser) profiles would be named \(p.name).")
            }
        }
    }

    private static func profilesAdd(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard let bs = try string(input, "browser"), let b = browser(named: bs) else { throw fail("Missing or unknown browser. See browsers.list.") }
        let p = BrowserProfile(browser: b.bundleId, directory: try string(input, "directory") ?? "",
                               name: try string(input, "name") ?? "", color: try color(try string(input, "color")))
        try store(env).update { c in
            let next = (c.profiles ?? []) + [p]
            try validate(next)
            c.profiles = next
        }
        return .success(describe(p))
    }

    private static func profileIndex(_ input: [String: Any], _ c: RuleStore.Contents) throws -> Int {
        guard let bs = try string(input, "browser"), let b = browser(named: bs) else { throw fail("Missing or unknown browser.") }
        let dir = try string(input, "directory") ?? ""
        guard let i = (c.profiles ?? []).firstIndex(where: { $0.browser == b.bundleId && $0.directory == dir })
        else { throw fail("No \(b.name) profile with folder \"\(dir)\". See profiles.list.") }
        return i
    }

    private static func profilesUpdate(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try store(env).update { c in
            var list = c.profiles ?? []
            let i = try profileIndex(input, c)
            let old = list[i]
            list[i] = BrowserProfile(browser: old.browser, directory: old.directory,
                                     name: try string(input, "name") ?? old.name,
                                     color: input["color"] == nil ? old.color : try color(try string(input, "color")))
            try validate(list)
            c.profiles = list
        }
        return .success()
    }

    private static func profilesRemove(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        try store(env).update { c in
            let i = try profileIndex(input, c)
            let p = (c.profiles ?? [])[i]
            let users = c.rules.enumerated().filter { $0.element.targets.contains(p.ref) }.map { $0.offset + 1 }
            if !users.isEmpty {
                throw fail("\(p.name) is used by rule \(users.map(String.init).joined(separator: ", ")); change or remove that rule first.")
            }
            if let k = (c.modifierRules ?? []).first(where: { $0.target == p.ref }) {
                throw fail("\(p.name) is used by the \(k.keys.symbols) modifier key rule; change or remove it first.")
            }
            if c.fallback == p.ref { throw fail("\(p.name) is where unmatched links open; set another fallback first.") }
            c.profiles?.remove(at: i)
        }
        return .success()
    }

    /// Reads each installed browser's profile list. Works when this process
    /// may read other apps' data (a terminal usually can); browsers it can't
    /// read are reported and their saved profiles kept.
    private static func profilesImport(_ env: AgentEnvironment) throws -> AgentResponse {
        var read: [String] = [], unreadable: [String] = []
        var live: [BrowserProfile] = []
        for b in env.installed where b.family != .plain {
            let found = ProfileCatalog.load(browsers: [b]).profiles
            if found.isEmpty { unreadable.append(b.name) } else { read.append(b.name); live += found }
        }
        if read.isEmpty {
            throw fail(unreadable.isEmpty ? "No installed browser has profiles to import."
                       : importFailure(env.installed.filter { unreadable.contains($0.name) }))
        }
        let readIDs = Set(live.map(\.browser))
        try store(env).update { c in
            c.profiles = (c.profiles ?? []).filter { !readIDs.contains($0.browser) } + live
        }
        return .success(["imported": live.count, "browsers": read, "couldNotRead": unreadable])
    }

    /// Why no browser's profiles could be read, from what each read ran into.
    static func importFailure(_ browsers: [Browser], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                              fullDiskAccess: Bool? = FullDiskAccess.isGranted()) -> String {
        let reasons = browsers.compactMap { b -> String? in
            guard let file = b.profilesFile(home: home) else { return nil }
            switch ProfileFileAccess.check(file) {
            case .readable: return "\(b.name)'s profile list has no profiles betterlink can use."
            case .missing: return "\(b.name) has no profile list yet (open it once first)."
            case let access: return access.explanation(browser: b.name, fullDiskAccess: fullDiskAccess)
            }
        }
        return (["Couldn't read profiles from \(browsers.map(\.name).joined(separator: ", "))."] + reasons)
            .joined(separator: " ")
    }

    // MARK: Settings

    private static func settingsGet(_ env: AgentEnvironment) throws -> AgentResponse {
        let c = try store(env).load()
        return .success(["settingsFolder": env.folder.directory.path, "showLog": c.showLog ?? false])
    }

    private static func settingsSet(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard let show = try bool(input, "showLog") else {
            throw fail("Nothing to set: settings.set takes showLog (true or false). The settings folder is changed with folder.set.")
        }
        try store(env).update { $0.showLog = show }
        return .success()
    }

    // MARK: config.ts

    private static func configInit(_ env: AgentEnvironment) throws -> AgentResponse {
        let f = env.folder.configFile
        if FileManager.default.fileExists(atPath: f.path) { throw fail("config.ts already exists at \(f.path); edit it instead.") }
        try ConfigLoader.writeEditorSupport(paths: env.folder, catalog: try catalog(env))
        guard FileManager.default.createFile(atPath: f.path, contents: Data(ConfigLoader.starterConfig.utf8),
                                             attributes: [.posixPermissions: 0o600])
        else { throw fail("Couldn't create \(f.path).") }
        return .success(["path": f.path])
    }

    /// Type-checks config.ts with the bundled compiler, exactly as the app
    /// does, and returns the errors.
    private static func configCheck(_ env: AgentEnvironment) -> AgentResponse {
        guard let compiler = env.compiler else { return .failure("The bundled TypeScript compiler isn't available.") }
        let cat = (try? catalog(env)) ?? ProfileCatalog(profiles: [])
        switch ConfigLoader.load(paths: env.folder, compiler: compiler, catalog: cat) {
        case .absent: return .success(["status": "absent", "errors": [String]()])
        case .loaded: return .success(["status": "ok", "errors": [String]()])
        case .failed(.compile(let errs)): return .success(["status": "errors", "errors": errs])
        case .failed(let e): return .success(["status": "errors", "errors": [e.description]])
        }
    }

    // MARK: Test

    private static func test(_ input: [String: Any], _ env: AgentEnvironment) throws -> AgentResponse {
        guard let link = try string(input, "link"), !link.isEmpty else { throw fail("Missing link.") }
        let held = try modifierKeys(input, "keys") ?? []
        let c = try store(env).load()
        var script: ConfigScript?
        // A config.ts that doesn't load is reported, never skipped silently:
        // the app keeps routing with the last version that loaded.
        var configError: String?
        if let compiler = env.compiler {
            switch ConfigLoader.load(paths: env.folder, compiler: compiler, catalog: try catalog(env, c)) {
            case .loaded(let s): script = s
            case .absent: break
            case .failed(let e): configError = e.description
            }
        }
        let router = Router(rules: c.rules, modifierRules: c.modifierRules ?? [], script: script, catalog: try catalog(env, c),
                            fallback: effectiveFallback(c.fallback, installed: env.installed),
                            installed: Set(env.installed.map(\.bundleId)))
        let d = router.decide(link, modifiers: held)
        var result: [String: Any]
        switch d.action {
        case .refuse: result = ["opens": false, "reason": d.reason]
        case .open(let p, let arg):
            result = ["opens": true, "browser": p.browser, "browserName": Browser.known(bundleId: p.browser)?.name ?? p.browser,
                      "profile": p.directory, "profileName": p.name, "link": arg, "reason": d.reason]
        }
        if let configError {
            result["configError"] = configError
            result["note"] = "config.ts didn't load, so this result skips it. The app keeps using the last config.ts that loaded, so it may route this link differently."
        }
        return .success(result)
    }
}
