import AppKit
import BetterlinkCore
import ServiceManagement

/// `Betterlink agent <command> ['<json input>']`: the machine interface the
/// betterlink CLI (Contents/Helpers/betterlink) calls. Prints one JSON
/// envelope, `{"version":1,"ok":…}`, and exits 0 when ok, 1 otherwise.
///
/// The core commands live in BetterlinkCore's `Agent`. The few that need the
/// app itself (default browser, open at login, settings folder) are here.
/// After a change, a running betterlink is told to re-read its files; the
/// notice carries no data, so another process can at most make it re-read.
enum AgentCommand {
    static let reloadNotice = Notification.Name("com.wkoutre.betterlink.reload")

    static let appCommands = [
        "default-browser.get", "default-browser.set",
        "login.get", "login.set",
        "folder.get", "folder.set",
        "menu-bar.get", "menu-bar.set",
        "updates.get", "updates.set",
        "toast.get", "toast.set",
        "sync.get", "sync.set", "sync.add", "sync.merge",
    ]

    static func run(_ args: [String]) -> Int32 {
        guard let command = args.first else {
            return emit(AgentResponseJSON.failure("Usage: Betterlink agent <command> ['<json>']. Commands: \(allCommands.joined(separator: ", "))."))
        }
        var input: [String: Any] = [:]
        if args.count > 1 {
            guard let data = args[1].data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return emit(AgentResponseJSON.failure("The input must be a JSON object, such as '{\"link\":\"https://example.com\"}'.")) }
            input = obj
        }
        let folder = SettingsFolder.resolve()
        let installed = Browser.known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }

        if tabCommands.contains(command) {
            let out = runTabCommand(command, input)
            if ["sidebar.settings.set", "tabs.helper.set"].contains(command) && isOK(out) { notifyApp() }
            return emit(out)
        }
        if TourAgent.commands.contains(command) {
            let defaults = MenuBarIcon.defaults()
            switch TourAgent.run(command, input: input, defaults: defaults, met: TourConditions.met(installed: installed)) {
            case .success(let data):
                defaults.synchronize()  // the running app reads it as soon as it is notified
                if command != "tour.status" { notifyApp() }
                return emit(AgentResponseJSON.success(data))
            case .failure(let refusal):
                return emit(AgentResponseJSON.failure(refusal.message))
            }
        }
        if ChangelogAgent.commands.contains(command) {
            let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            switch ChangelogAgent.run(command, input: input, changelog: Changelog.bundled(), installed: installed) {
            case .success(let data): return emit(AgentResponseJSON.success(data))
            case .failure(let refusal): return emit(AgentResponseJSON.failure(refusal.message))
            }
        }
        if appCommands.contains(command) {
            let out = runAppCommand(command, input, folder: folder)
            if changes(command) && isOK(out) { notifyApp() }
            return emit(out)
        }
        let ts = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("typescript")
        let needsCompiler = command == "config.check" || command == "test"
        let compiler = needsCompiler ? try? TypeScriptCompiler(typescriptJS: ts.appendingPathComponent("typescript.js"),
                                                               libDirectory: ts.appendingPathComponent("lib")) : nil
        guard Agent.commands.contains(command) else {
            return emit(AgentResponseJSON.failure("Unknown command \(command). Commands: \(allCommands.joined(separator: ", "))."))
        }
        let response = Agent.run(command, input: input, env: AgentEnvironment(folder: folder, installed: installed, compiler: compiler,
                                                                            symbolExists: { SymbolCheck.exists($0) }))
        let out = response.json()
        if changes(command) && response.ok { notifyApp() }
        return emit(out)
    }

    static var allCommands: [String] { Agent.commands + appCommands + tabCommands + TourAgent.commands + ChangelogAgent.commands }

    private static func changes(_ command: String) -> Bool {
        !command.hasSuffix(".get") && !command.hasSuffix(".list") && !["status", "test", "config.path", "config.check", "sync.paused", "sync.history"].contains(command)
    }

    private static func isOK(_ json: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?["ok"] as? Bool == true
    }

    private static func emit(_ json: Data) -> Int32 {
        FileHandle.standardOutput.write(json)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return isOK(json) ? 0 : 1
    }

    /// Tells a running betterlink to re-read rules.json, config.ts and its
    /// settings folder. Carries nothing.
    static func notifyApp() {
        DistributedNotificationCenter.default().postNotificationName(reloadNotice, object: nil, userInfo: nil,
                                                                    deliverImmediately: true)
    }

    private static func runAppCommand(_ command: String, _ input: [String: Any], folder: SettingsFolder) -> Data {
        switch command {
        case "default-browser.get":
            return AgentResponseJSON.success(["isDefault": isDefaultBrowser()])
        case "default-browser.set":
            if isDefaultBrowser() { return AgentResponseJSON.success(["isDefault": true]) }
            // The same three registrations as the window's button. macOS
            // asks the user to confirm once.
            let app = Bundle.main.bundleURL
            for register in [
                { (done: @escaping @Sendable ((any Error)?) -> Void) in NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http", completion: done) },
                { done in NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https", completion: done) },
                { done in NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html, completion: done) },
            ] as [(@escaping @Sendable ((any Error)?) -> Void) -> Void] {
                waitWhileRunLoopRuns(seconds: 120, register)
            }
            return AgentResponseJSON.success([
                "isDefault": isDefaultBrowser(),
                "note": "macOS asks the user to confirm; until they do, betterlink is not the default.",
            ])
        case "login.get":
            let st = SMAppService.mainApp.status
            let word = switch st {
            case .enabled: "enabled"
            case .requiresApproval: "requiresApproval"
            case .notRegistered: "notRegistered"
            case .notFound: "notFound"
            @unknown default: "unknown"
            }
            return AgentResponseJSON.success(["enabled": st == .enabled, "status": word])
        case "login.set":
            guard let n = input["enabled"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                return AgentResponseJSON.failure("Give enabled: true or false.")
            }
            let on = n.boolValue
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                return AgentResponseJSON.success(["enabled": SMAppService.mainApp.status == .enabled])
            } catch {
                return AgentResponseJSON.failure("Couldn't change Open at login: \(error.localizedDescription). Use betterlink's Permissions page.")
            }
        case "menu-bar.get":
            return AgentResponseJSON.success(["shown": MenuBarIcon.isShown(in: MenuBarIcon.defaults())])
        case "menu-bar.set":
            guard let n = input["shown"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                return AgentResponseJSON.failure("Give shown: true or false.")
            }
            let d = MenuBarIcon.defaults()
            MenuBarIcon.setShown(n.boolValue, in: d)
            d.synchronize()  // the running app reads it as soon as it is notified
            return AgentResponseJSON.success([
                "shown": n.boolValue,
                "note": "This Mac only. With the icon hidden, open betterlink from Spotlight or Finder to see its window.",
            ])
        case "updates.get":
            let d = UpdateChecks.defaults()
            return AgentResponseJSON.success([
                "automatic": UpdateChecks.isAutomatic(in: d),
                "install": UpdateChecks.installsAutomatically(in: d),
                "checkEverySeconds": Int(UpdateChecks.checkInterval),
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "updaterInThisBuild": UpdateChecks.updaterCanRun(info: Bundle.main.infoDictionary ?? [:]),
            ])
        case "updates.set":
            func flag(_ key: String) -> Bool?? {
                guard let v = input[key] else { return .some(nil) }
                guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
                return .some(n.boolValue)
            }
            guard let automatic = flag("automatic"), let install = flag("install") else {
                return AgentResponseJSON.failure("Give automatic and install as true or false.")
            }
            if automatic == nil && install == nil {
                return AgentResponseJSON.failure("Give automatic (true or false), install (true or false), or both.")
            }
            let d = UpdateChecks.defaults()
            if let automatic { UpdateChecks.setAutomatic(automatic, in: d) }
            if let install { UpdateChecks.setInstallsAutomatically(install, in: d) }
            d.synchronize()
            return AgentResponseJSON.success([
                "automatic": UpdateChecks.isAutomatic(in: d),
                "install": UpdateChecks.installsAutomatically(in: d),
            ])
        case "toast.get":
            let d = MenuBarIcon.defaults()
            return AgentResponseJSON.success(["shown": LinkToast.isShown(in: d), "position": LinkToast.position(in: d).rawValue])
        case "toast.set":
            let shown = input["shown"]
            let position = input["position"]
            if shown == nil && position == nil { return AgentResponseJSON.failure("Give shown (true or false), position (top or bottom), or both.") }
            var newShown: Bool?
            if let shown {
                guard let n = shown as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else {
                    return AgentResponseJSON.failure("Give shown: true or false.")
                }
                newShown = n.boolValue
            }
            var newPosition: LinkToast.Position?
            if let position {
                guard let s = position as? String, let p = LinkToast.Position(rawValue: s) else {
                    return AgentResponseJSON.failure("Give position: top or bottom.")
                }
                newPosition = p
            }
            let d = MenuBarIcon.defaults()
            if let newShown { LinkToast.setShown(newShown, in: d) }
            if let newPosition { LinkToast.setPosition(newPosition, in: d) }
            d.synchronize()
            return AgentResponseJSON.success(["shown": LinkToast.isShown(in: d), "position": LinkToast.position(in: d).rawValue,
                                              "note": "This Mac only."])
        case "sync.get":
            return AgentResponseJSON.success(syncSettings(folder: folder))
        case "sync.set":
            return setSyncSettings(input, folder: folder)
        case "sync.add", "sync.merge":
            return requestOffer(command == "sync.merge", input, folder: folder)
        case "folder.get":
            return AgentResponseJSON.success(["path": folder.directory.path,
                                              "isStandard": folder.directory == SettingsFolder.defaultDirectory])
        case "folder.set":
            if !(ProcessInfo.processInfo.environment["BETTERLINK_HOME"] ?? "").isEmpty {
                return AgentResponseJSON.failure("BETTERLINK_HOME is set, so the settings folder can't be changed.")
            }
            let target: SettingsFolder
            if let path = input["path"] as? String, !path.isEmpty {
                target = SettingsFolder(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
            } else if let n = input["standard"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID(), n.boolValue {
                target = SettingsFolder(directory: SettingsFolder.defaultDirectory)
            } else {
                return AgentResponseJSON.failure("Give path (a folder) or standard: true.")
            }
            do {
                try folder.copySettings(to: target)
                if target.directory == SettingsFolder.defaultDirectory {
                    UserDefaults.standard.removeObject(forKey: SettingsFolder.defaultsKey)
                } else {
                    UserDefaults.standard.set(target.directory.path, forKey: SettingsFolder.defaultsKey)
                }
                UserDefaults.standard.synchronize()  // the running app reads it as soon as it is notified
                return AgentResponseJSON.success(["path": target.directory.path])
            } catch {
                return AgentResponseJSON.failure("Didn't switch folders: \(error)")
            }
        default:
            return AgentResponseJSON.failure("Unknown command \(command).")
        }
    }

    // MARK: Sync

    /// General › Sync on this Mac, from the keys SyncController uses.
    private static func syncSettings(folder: SettingsFolder) -> [String: Any] {
        let d = MenuBarIcon.defaults()
        let selection = SyncDefaults.selection(in: d)
        let names = Dictionary(((try? SidebarStore(folder: folder).load())?.profiles ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        return [
            "on": SyncDefaults.folder(in: d) != nil,
            "folder": SyncDefaults.folder(in: d)?.path ?? NSNull(),
            "global": selection.global,
            // The other Macs in the folder, with when each last synced.
            "macs": otherMacs(d),
            // Sidebar Profiles other Macs share that this Mac hasn't added (sync add, sync merge).
            "offered": offers(d, folder: folder).map { o -> [String: Any] in
                ["id": o.id.uuidString, "name": o.name, "sameNameAs": o.sameNameAs?.uuidString ?? NSNull()]
            },
            "profiles": selection.profiles.sorted { $0.key.uuidString < $1.key.uuidString }.map { entry -> [String: Any] in
                ["id": entry.key.uuidString, "name": names[entry.key] ?? NSNull(),
                 "favorites": entry.value.favorites, "folders": entry.value.folders, "appearance": entry.value.appearance]
            },
        ]
    }

    /// The other Macs in the sync folder, with when each last synced; none when Sync is off.
    private static func otherMacs(_ d: UserDefaults) -> [[String: Any]] {
        guard let root = SyncDefaults.folder(in: d) else { return [] }
        let me: String? = ProcessInfo.processInfo.environment["BETTERLINK_SYNC_DEVICE"] ?? d.string(forKey: "sync.device")
        let now = Date()
        return SyncFolder(root).peers(except: me).map { $0.describe(now: now) }
    }

    /// What every Mac's file in the sync folder holds, merged, and the
    /// Sidebar Profiles in it this Mac hasn't added.
    private static func shared(_ d: UserDefaults) -> SyncState? {
        guard let root = SyncDefaults.folder(in: d) else { return nil }
        return SyncFolder(root).readAll().files.reduce(SyncState()) { $0.merged(with: $1.state) }
    }

    private static func offers(_ d: UserDefaults, folder: SettingsFolder) -> [SyncOffer] {
        guard let state = shared(d) else { return [] }
        return SyncModel.offers(state: state, selected: Set(SyncDefaults.selection(in: d).profiles.keys),
                                library: (try? SidebarStore(folder: folder).load()) ?? SidebarLibrary())
    }

    /// `sync add` and `sync merge`: noted in sync-local.json for the app's
    /// next sync, which copies the profile in before it syncs it (Sync
    /// settings' Add and Merge do the same).
    private static func requestOffer(_ merge: Bool, _ input: [String: Any], folder: SettingsFolder) -> Data {
        let d = MenuBarIcon.defaults()
        guard let state = shared(d) else { return AgentResponseJSON.failure("Sync is off on this Mac (sync set --folder).") }
        guard let wanted = (input["profile"] as? String)?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty else {
            return AgentResponseJSON.failure("Give profile: a Sidebar Profile another Mac shares, by name or id (sync get lists them under offered).")
        }
        let all = offers(d, folder: folder)
        let hits = all.filter { $0.id.uuidString.lowercased() == wanted.lowercased() || SyncModel.sameName($0.name, wanted) }
        guard let offer = hits.first else {
            return AgentResponseJSON.failure("No Sidebar Profile \"\(wanted)\" is waiting to be added from another Mac (sync get lists them under offered).")
        }
        let store = SyncLocalStore(folder: folder)
        do {
            if merge {
                guard offer.sameNameAs != nil else {
                    return AgentResponseJSON.failure("No Sidebar Profile on this Mac is named \"\(offer.name)\"; use sync add.")
                }
                if let root = SyncDefaults.folder(in: d) {
                    let me = ProcessInfo.processInfo.environment["BETTERLINK_SYNC_DEVICE"] ?? d.string(forKey: "sync.device")
                    let old = SyncFolder(root).readAll(except: me).files.filter { !($0.features ?? []).contains(SyncDeviceFile.mergeFeature) }
                    if !old.isEmpty {
                        return AgentResponseJSON.failure("Merge needs the latest betterlink on \(old.map(\.name).sorted().joined(separator: ", ")) first.")
                    }
                }
                let library = (try? SidebarStore(folder: folder).load()) ?? SidebarLibrary()
                let group = SyncModel.mergeGroup(offer.id, state: state, selected: Set(SyncDefaults.selection(in: d).profiles.keys), library: library)
                try store.update { $0.merging = ($0.merging ?? []) + [group] }
                return AgentResponseJSON.success(["merging": group.map(\.uuidString), "name": offer.name,
                                                  "note": "They become one Sidebar Profile on every Mac, with the favorites and folders of all of them. " + Agent.syncNote])
            }
            guard hits.count == 1 else {
                return AgentResponseJSON.failure("More than one shared Sidebar Profile is named \"\(wanted)\"; give its id (sync get), or merge them (sync merge).")
            }
            try store.update { if !($0.adding ?? []).contains(offer.id) { $0.adding = ($0.adding ?? []) + [offer.id] } }
            return AgentResponseJSON.success(["adding": offer.id.uuidString, "name": offer.name, "note": Agent.syncNote])
        } catch {
            return AgentResponseJSON.failure("Couldn't save that: \(error.localizedDescription)")
        }
    }

    private static func setSyncSettings(_ input: [String: Any], folder: SettingsFolder) -> Data {
        func bool(_ key: String) -> Bool?? {
            guard let v = input[key] else { return .some(nil) }
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return .some(n.boolValue)
        }
        guard let off = bool("off"), let global = bool("global") else {
            return AgentResponseJSON.failure("off and global must be true or false.")
        }
        let d = MenuBarIcon.defaults()
        var target: URL?
        if let v = input["folder"] {
            guard off != true else { return AgentResponseJSON.failure("Give folder or off, not both.") }
            guard let path = v as? String, !path.isEmpty else { return AgentResponseJSON.failure("folder must be a folder's path.") }
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return AgentResponseJSON.failure("No folder at \(url.path). Make it first, inside a folder Dropbox, Google Drive or iCloud Drive keeps in sync.")
            }
            target = url
        }
        var selection = SyncDefaults.selection(in: d)
        var changedSelection = false
        if let global { selection.global = global; changedSelection = true }
        if let v = input["profile"] {
            guard let wanted = v as? String, !wanted.isEmpty else { return AgentResponseJSON.failure("profile must be a Sidebar Profile's name or id (sidebar list).") }
            let profiles = (try? SidebarStore(folder: folder).load())?.profiles ?? []
            let hits = profiles.filter { $0.id.uuidString.lowercased() == wanted.lowercased() || $0.name.lowercased() == wanted.lowercased() }
            guard hits.count == 1, let profile = hits.first else {
                return AgentResponseJSON.failure(hits.isEmpty ? "No Sidebar Profile \"\(wanted)\" (sidebar list)." : "More than one Sidebar Profile is named \"\(wanted)\"; give its id (sidebar list).")
            }
            guard let parts = input["parts"] as? [String] else {
                return AgentResponseJSON.failure("With profile, give parts: a list of favorites, folders and name; an empty list keeps the profile on this Mac.")
            }
            let known = ["favorites", "folders", "name"]
            if let bad = parts.first(where: { !known.contains($0) }) {
                return AgentResponseJSON.failure("No part \"\(bad)\". Parts: \(known.joined(separator: ", ")).")
            }
            selection.profiles[profile.id] = parts.isEmpty ? nil
                : SyncSelection.Parts(favorites: parts.contains("favorites"), folders: parts.contains("folders"), appearance: parts.contains("name"))
            changedSelection = true
        } else if input["parts"] != nil {
            return AgentResponseJSON.failure("parts needs profile: the Sidebar Profile they belong to.")
        }
        if target == nil, off != true, !changedSelection {
            return AgentResponseJSON.failure("Give any of folder, off, global, or profile with parts.")
        }
        if let target { SyncDefaults.setFolder(target, in: d) }
        if off == true {
            SyncDefaults.setFolder(nil, in: d)
            // Off: no rule is unresolved any more (rules list reads this).
            try? SyncLocalStore(folder: folder).update { $0.unresolvedRules = nil; $0.missingProfiles = nil }
        }
        if target != nil || off == true {
            // A hold and its answer were about the old folder.
            try? SyncLocalStore(folder: folder).update { $0.held = nil; $0.decision = nil }
        }
        if changedSelection { SyncDefaults.setSelection(selection, in: d) }
        d.synchronize()  // the running app reads it as soon as it is notified
        var out = syncSettings(folder: folder)
        out["note"] = "This Mac only. A running betterlink starts syncing at once; otherwise it does when it next opens."
        return AgentResponseJSON.success(out)
    }

    /// betterlink is the default browser only if it opens both http and https links.
    static func isDefaultBrowser() -> Bool {
        let me = Bundle.main.bundleURL.standardizedFileURL
        return ["http://example.com", "https://example.com"].allSatisfy {
            NSWorkspace.shared.urlForApplication(toOpen: URL(string: $0)!)?.standardizedFileURL == me
        }
    }

    /// Starts an asynchronous call and keeps the run loop turning until it
    /// finishes, so a completion delivered on the main queue still arrives.
    private static func waitWhileRunLoopRuns(seconds: TimeInterval,
                                             _ start: (@escaping @Sendable ((any Error)?) -> Void) -> Void) {
        final class Flag: @unchecked Sendable { var done = false }
        let flag = Flag()
        start { _ in DispatchQueue.main.async { flag.done = true } }
        let deadline = Date().addingTimeInterval(seconds)
        while !flag.done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
    }
}

/// The same envelope as BetterlinkCore's AgentResponse, for the app's own commands.
enum AgentResponseJSON {
    static func success(_ data: [String: Any]) -> Data { encode(["version": 1, "ok": true, "data": data]) }
    static func failure(_ message: String) -> Data { encode(["version": 1, "ok": false, "error": message]) }
    private static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }
}

/// Whether this Mac draws a built-in symbol (SF Symbols) by that name: what a
/// folder icon's symbol is checked against, from the menu and the command.
enum SymbolCheck {
    static func exists(_ name: String) -> Bool {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}
