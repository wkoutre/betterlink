import AppKit
import BetterlinkCore
import TabSyncCore

/// `betterlink tabs …` and `betterlink sidebar settings …`: the live side of
/// the sidebar for agents. Tab commands talk to the browsers' Tabs hosts over
/// the same sockets the app uses (SyncHub), so they work while betterlink
/// runs or not, as long as a browser with the Tabs extension is open. Tab ids
/// are the browser's own (tabs list).
extension AgentCommand {
    static let tabCommands = [
        "tabs.list", "tabs.open", "tabs.close", "tabs.activate", "tabs.move", "tabs.mute",
        "tabs.duplicate", "tabs.reload", "tabs.navigate", "tabs.new-window", "tabs.close-others", "tabs.close-below",
        "tabs.extension",
        "sidebar.settings.get", "sidebar.settings.set",
    ]

    static func runTabCommand(_ command: String, _ input: [String: Any]) -> Data {
        if command == "sidebar.settings.get" { return AgentResponseJSON.success(sidebarSettings()) }
        if command == "sidebar.settings.set" { return setSidebarSettings(input) }
        if command == "tabs.extension" { return tabsExtension() }
        let hub = SyncHub(onChange: { _ in })
        hub.start()
        let sessions = waitForSessions(hub)
        guard !sessions.isEmpty else {
            return AgentResponseJSON.failure("No browser with the betterlink Tabs extension is connected. Open Chrome (or another attached browser) with the extension on.")
        }
        do {
            let out = try tabCommand(command, input, hub, sessions)
            // Give the host a moment to take the command before this process exits.
            if command != "tabs.list" { Thread.sleep(forTimeInterval: 0.3) }
            return AgentResponseJSON.success(out)
        } catch let e as TabError {
            return AgentResponseJSON.failure(e.message)
        } catch {
            return AgentResponseJSON.failure("\(error)")
        }
    }

    struct TabError: Error { let message: String }

    /// Where browsers load the Tabs extension from on this Mac, after making
    /// sure this app's copy is there (the Tabs page's Show in Finder).
    static func tabsExtension() -> Data {
        let folder = ExtensionCopy.folder
        if let bundled = ExtensionCopy.bundled() {
            do { try ExtensionCopy.refresh(from: bundled, to: folder) }
            catch { return AgentResponseJSON.failure("Couldn't put the Tabs extension in its folder: \(error.localizedDescription)") }
        }
        guard let version = ExtensionCopy.version(of: folder) else {
            return AgentResponseJSON.failure("This build of betterlink has no Tabs extension in it. Load browser-extension from the source folder.")
        }
        return AgentResponseJSON.success([
            "path": folder.path,
            "version": version,
            "id": HostRegistration.extensionId,
            "load": "Once per browser profile: open chrome://extensions, turn on Developer mode, click Load unpacked and choose this folder. Leave Developer mode on. The extension then updates with betterlink.",
        ])
    }

    /// Waits until every connected host has said hello and sent its windows,
    /// at most 2 s.
    static func waitForSessions(_ hub: SyncHub) -> [BrowserSession] {
        let deadline = Date().addingTimeInterval(2)
        var last: [BrowserSession] = []
        while Date() < deadline {
            last = hub.current
            if !last.isEmpty, last.allSatisfy({ $0.extensionVersion != nil && !$0.store.orderedWindows.isEmpty }) {
                // One more beat for the rest of the snapshot.
                Thread.sleep(forTimeInterval: 0.15)
                return hub.current
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return last
    }

    static func describe(_ s: BrowserSession) -> [String: Any] {
        [
            "browser": s.browser,
            "extension": s.extensionVersion ?? NSNull(),
            "windows": s.store.orderedWindows.map { w in
                [
                    "id": w.window.id, "focused": w.window.focused, "incognito": w.window.incognito ?? false,
                    "tabs": w.tabs.enumerated().map { i, t in
                        ["id": t.id, "position": i + 1, "title": t.title, "url": t.url, "active": t.active, "muted": t.muted] as [String: Any]
                    },
                ] as [String: Any]
            },
        ]
    }

    private static func int(_ input: [String: Any], _ key: String) throws -> Int? {
        guard let v = input[key], !(v is NSNull) else { return nil }
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n), let i = Int(exactly: n) else {
            throw TabError(message: "\(key) must be a whole number.")
        }
        return i
    }

    private static func webURL(_ input: [String: Any]) throws -> String {
        guard let s = (input["url"] as? String)?.trimmingCharacters(in: .whitespaces), let u = URL(string: s),
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""), u.host != nil else {
            throw TabError(message: "Give url: a full http or https address.")
        }
        return s
    }

    /// The session and window holding tab `id`. Two browsers can each have a
    /// tab with the same id: then `browser` (a name or bundle id) says which.
    private static func find(_ id: Int, in sessions: [BrowserSession], browser: String? = nil) throws -> (BrowserSession, Int) {
        var hits: [(BrowserSession, Int)] = []
        for s in sessions {
            if let browser, s.browser.lowercased() != browser.lowercased(), Browser.known.first(where: { $0.name == s.browser })?.bundleId.lowercased() != browser.lowercased() { continue }
            for w in s.store.orderedWindows where w.tabs.contains(where: { $0.id == id }) { hits.append((s, w.window.id)) }
        }
        if hits.count == 1 { return hits[0] }
        if hits.isEmpty { throw TabError(message: "No open tab \(id)\(browser.map { " in \($0)" } ?? "") (tabs list).") }
        throw TabError(message: "Tab \(id) is open in more than one browser (\(hits.map(\.0.browser).joined(separator: ", "))); give browser.")
    }

    private static func need(_ s: BrowserSession, _ op: Command.Op) throws {
        guard s.can(op) else {
            throw TabError(message: "This browser's Tabs extension (\(s.extensionVersion ?? "old")) can't \(op.rawValue); reload the extension to update it.")
        }
    }

    /// The tabs Close Other Tabs / Below leave open in `tabs`: saved links'
    /// tabs and held tabs (Agent.sparedTabs).
    private static func spared(_ tabs: [BrowserTab]) throws -> Set<Int> {
        // Unreadable, it can't say which tabs are saved links': close nothing.
        let lib: SidebarLibrary
        do { lib = try SidebarStore(folder: SettingsFolder.resolve()).load() } catch {
            throw TabError(message: "Can't read sidebar.json (\(error)), so this can't tell which tabs saved links hold; nothing was closed.")
        }
        let remembered = MenuBarIcon.defaults().dictionary(forKey: "sidebar.heldTabs") as? [String: [String: [String]]] ?? [:]
        return Agent.sparedTabs(tabs.map { (id: $0.id, url: $0.url) }, library: lib, remembered: remembered)
    }

    private static func tabCommand(_ command: String, _ input: [String: Any], _ hub: SyncHub, _ sessions: [BrowserSession]) throws -> [String: Any] {
        if let b = input["browser"], !(b is NSNull), !(b is String) { throw TabError(message: "browser must be text: a name or bundle id.") }
        func tab() throws -> (Int, BrowserSession, Int) {
            guard let id = try int(input, "tab") else { throw TabError(message: "Give tab: a tab id (tabs list).") }
            let (s, w) = try find(id, in: sessions, browser: input["browser"] as? String)
            return (id, s, w)
        }
        switch command {
        case "tabs.list":
            return ["browsers": sessions.map(describe)]
        case "tabs.open":
            let url = try webURL(input)
            let windowId = try int(input, "window")
            let browser = input["browser"] as? String
            let s = try windowId.map { w in
                let hits = sessions.filter { s in
                    s.store.orderedWindows.contains { $0.window.id == w }
                        && (browser == nil || s.browser.lowercased() == browser!.lowercased()
                            || Browser.known.first(where: { $0.name == s.browser })?.bundleId.lowercased() == browser!.lowercased())
                }
                if hits.count > 1 { throw TabError(message: "Window \(w) is open in more than one browser; give browser.") }
                guard let s = hits.first else { throw TabError(message: "No open window \(w) (tabs list).") }
                return s
            } ?? sessions.first(where: { $0.store.orderedWindows.contains { $0.window.focused } }) ?? sessions[0]
            hub.send(.open(url, windowId: windowId), to: s.socketPath)
            return ["opened": url, "browser": s.browser]
        case "tabs.close":
            var ids: [Int] = []
            if let list = input["tabs"] {
                guard let items = list as? [Any] else { throw TabError(message: "tabs must be a list of tab ids.") }
                for item in items {
                    guard let n = item as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n), let i = Int(exactly: n) else {
                        throw TabError(message: "tabs must be whole-number tab ids (tabs list).")
                    }
                    ids.append(i)
                }
            }
            if let one = try int(input, "tab") { ids.append(one) }
            guard !ids.isEmpty else { throw TabError(message: "Give tab (one id) or tabs (a list of ids).") }
            var bySession: [String: (BrowserSession, [Int])] = [:]
            for id in ids {
                let (s, _) = try find(id, in: sessions, browser: input["browser"] as? String)
                bySession[s.socketPath, default: (s, [])].1.append(id)
            }
            for (s, list) in bySession.values {
                if s.can(.closeMany) { hub.send(.close(list), to: s.socketPath) } else { for id in list { hub.send(.close(id), to: s.socketPath) } }
            }
            return ["closed": ids]
        case "tabs.activate":
            let (id, s, _) = try tab()
            hub.send(.activate(id), to: s.socketPath)
            return ["activated": id]
        case "tabs.move":
            let (id, s, from) = try tab()
            try need(s, .move)
            guard let pos = try int(input, "position"), pos >= 1 else { throw TabError(message: "Give position: where in the window, from 1.") }
            let windowId = try int(input, "window")
            hub.send(.move(id, to: pos - 1, windowId: windowId == from ? nil : windowId), to: s.socketPath)
            return ["moved": id, "position": pos]
        case "tabs.mute":
            let (id, s, _) = try tab()
            try need(s, .mute)
            guard let n = input["muted"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw TabError(message: "Give muted: true or false.") }
            hub.send(.mute(id, n.boolValue), to: s.socketPath)
            return ["tab": id, "muted": n.boolValue]
        case "tabs.duplicate":
            let (id, s, _) = try tab()
            try need(s, .duplicate)
            hub.send(.duplicate(id), to: s.socketPath)
            return ["duplicated": id]
        case "tabs.reload":
            let (id, s, _) = try tab()
            try need(s, .reload)
            hub.send(.reload(id), to: s.socketPath)
            return ["reloaded": id]
        case "tabs.navigate":
            let (id, s, _) = try tab()
            try need(s, .navigate)
            let url = try webURL(input)
            hub.send(.navigate(id, to: url), to: s.socketPath)
            return ["tab": id, "url": url]
        case "tabs.new-window":
            let (id, s, _) = try tab()
            try need(s, .newWindow)
            hub.send(.newWindow(with: id), to: s.socketPath)
            return ["movedToNewWindow": id]
        case "tabs.close-others", "tabs.close-below":
            let (id, s, w) = try tab()
            guard let window = s.store.orderedWindows.first(where: { $0.window.id == w }) else { return ["closed": []] }
            let tabs = window.tabs
            let held = try spared(tabs)
            let index = tabs.firstIndex { $0.id == id } ?? 0
            let candidates = command == "tabs.close-below" ? Array(tabs.dropFirst(index + 1)) : tabs.filter { $0.id != id }
            let close = candidates.map(\.id).filter { !held.contains($0) }
            if !close.isEmpty {
                if s.can(.closeMany) { hub.send(.close(close), to: s.socketPath) } else { for c in close { hub.send(.close(c), to: s.socketPath) } }
            }
            return ["closed": close, "keptHeldBySavedLinks": candidates.map(\.id).filter { held.contains($0) }]
        default:
            throw TabError(message: "Unknown command \(command).")
        }
    }

    // MARK: Sidebar settings

    /// The Tabs page's sidebar settings, from the same keys SidebarController uses.
    static func sidebarSettings() -> [String: Any] {
        let d = MenuBarIcon.defaults()
        let w = d.double(forKey: "sidebar.width")
        return [
            "enabled": d.bool(forKey: "sidebar.enabled"),
            "shown": !d.bool(forKey: "sidebar.collapsed"),
            "side": d.string(forKey: "sidebar.side") ?? "right",
            "width": w >= 200 ? w : 280,
            "takeOverTabs": d.object(forKey: "sidebar.takeOverTabs") as? Bool ?? true,
            "browsers": (d.array(forKey: "sidebar.browsers") as? [String])
                // Until changed, every installed Chromium browser and Safari (SidebarController.defaultBrowsers).
                ?? Browser.known.filter { ($0.family == .chromium || $0.bundleId == "com.apple.Safari")
                    && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }.map(\.bundleId).sorted(),
        ]
    }

    static func setSidebarSettings(_ input: [String: Any]) -> Data {
        let d = MenuBarIcon.defaults()
        func bool(_ k: String) -> Bool?? {
            guard let v = input[k] else { return .some(nil) }
            guard let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
            return .some(n.boolValue)
        }
        guard let enabled = bool("enabled"), let shown = bool("shown"), let take = bool("takeOverTabs") else {
            return AgentResponseJSON.failure("enabled, shown and takeOverTabs must be true or false.")
        }
        var side: String?
        if let s = input["side"] {
            guard let s = s as? String, SidebarSide(rawValue: s) != nil else {
                return AgentResponseJSON.failure("side must be \(SidebarSide.allCases.map(\.rawValue).joined(separator: ", ")) (auto: whichever side has room).")
            }
            side = s
        }
        var width: Double?
        if let v = input["width"] {
            guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), (200...440).contains(n.doubleValue) else {
                return AgentResponseJSON.failure("width must be a number of points from 200 to 440.")
            }
            width = (n.doubleValue / 10).rounded() * 10
        }
        var browsers: [String]?
        if let v = input["browsers"] {
            guard let list = v as? [String] else { return AgentResponseJSON.failure("browsers must be a list of bundle ids or names.") }
            var ids: [String] = []
            for b in list {
                guard let known = Browser.known.first(where: { $0.bundleId.lowercased() == b.lowercased() || $0.name.lowercased() == b.lowercased() }) else {
                    return AgentResponseJSON.failure("No browser \"\(b)\" betterlink knows (browsers list).")
                }
                ids.append(known.bundleId)
            }
            browsers = Array(Set(ids)).sorted()
        }
        if enabled == nil, shown == nil, take == nil, side == nil, width == nil, browsers == nil {
            return AgentResponseJSON.failure("Give any of enabled, shown, side, width, takeOverTabs, browsers.")
        }
        if let enabled { d.set(enabled, forKey: "sidebar.enabled") }
        if let shown { d.set(!shown, forKey: "sidebar.collapsed") }
        if let take { d.set(take, forKey: "sidebar.takeOverTabs") }
        if let side { d.set(side, forKey: "sidebar.side") }
        if let width { d.set(width, forKey: "sidebar.width") }
        if let browsers { d.set(browsers, forKey: "sidebar.browsers") }
        d.synchronize()  // the running app reads it as soon as it is notified
        var out = sidebarSettings()
        out["note"] = "This Mac only. Turning the sidebar on needs Accessibility for betterlink (Permissions page)."
        return AgentResponseJSON.success(out)
    }
}
