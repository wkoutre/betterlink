import Foundation

/// A browser betterlink can open links in.
public struct Browser: Equatable, Hashable, Sendable, Identifiable {
    public enum Family: String, Codable, Sendable {
        /// Chrome and its relatives: profiles listed in "Local State", opened
        /// with --profile-directory.
        case chromium
        /// Firefox and its relatives: profiles listed in profiles.ini, opened with -P.
        case firefox
        /// No profile betterlink can pick (Safari, Arc): the link just opens in the browser.
        case plain
    }

    public let name: String
    public let bundleId: String
    public let family: Family
    /// The browser's data folder under ~/Library/Application Support, when it
    /// keeps a profile list there.
    public let dataFolder: String?
    /// The browser refuses a second process, so a profile can't travel on a
    /// fresh command line: betterlink switches the running browser to the
    /// profile by AppleScript instead (Dia, whose profiles are its spaces).
    public let switchesProfileByScript: Bool
    public var id: String { bundleId }

    public init(name: String, bundleId: String, family: Family, dataFolder: String?,
                switchesProfileByScript: Bool = false) {
        self.name = name; self.bundleId = bundleId; self.family = family; self.dataFolder = dataFolder
        self.switchesProfileByScript = switchesProfileByScript
    }

    /// The file listing the browser's profiles, under `home`.
    public func profilesFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        guard let dataFolder else { return nil }
        let dir = home.appendingPathComponent("Library/Application Support").appendingPathComponent(dataFolder)
        switch family {
        case .chromium: return dir.appendingPathComponent("Local State")
        case .firefox: return dir.appendingPathComponent("profiles.ini")
        case .plain: return nil
        }
    }

    public static let brave = known[0]

    /// Browsers betterlink knows. Bundle ids and data folders for most come
    /// from Finicky's browsers.json (github.com/johnste/finicky, MIT); Dia's
    /// from Raycast's Dia extension. Opening a link in a profile was tested by
    /// hand with Brave only; the rest follow their family's documented flags,
    /// except Dia, which allows one process only (see `DiaSpace`).
    /// Order matters: with no usable fallback, links open in the first
    /// installed Chromium browser here (the README lists this order).
    public static let known: [Browser] = [
        Browser(name: "Brave", bundleId: "com.brave.Browser", family: .chromium, dataFolder: "BraveSoftware/Brave-Browser"),
        Browser(name: "Brave Nightly", bundleId: "com.brave.Browser.nightly", family: .chromium, dataFolder: "BraveSoftware/Brave-Browser-Nightly"),
        Browser(name: "Google Chrome", bundleId: "com.google.Chrome", family: .chromium, dataFolder: "Google/Chrome"),
        Browser(name: "Google Chrome Beta", bundleId: "com.google.Chrome.beta", family: .chromium, dataFolder: "Google/Chrome Beta"),
        Browser(name: "Google Chrome Canary", bundleId: "com.google.Chrome.canary", family: .chromium, dataFolder: "Google/Chrome Canary"),
        Browser(name: "Chromium", bundleId: "org.chromium.Chromium", family: .chromium, dataFolder: "Chromium"),
        Browser(name: "Microsoft Edge", bundleId: "com.microsoft.edgemac", family: .chromium, dataFolder: "Microsoft Edge"),
        Browser(name: "Dia", bundleId: "company.thebrowser.dia", family: .chromium, dataFolder: "Dia/User Data", switchesProfileByScript: true),
        Browser(name: "Comet", bundleId: "ai.perplexity.comet", family: .chromium, dataFolder: "Comet"),
        Browser(name: "Vivaldi", bundleId: "com.vivaldi.Vivaldi", family: .chromium, dataFolder: "Vivaldi"),
        Browser(name: "Helium", bundleId: "net.imput.helium", family: .chromium, dataFolder: "net.imput.helium"),
        Browser(name: "Opera", bundleId: "com.operasoftware.Opera", family: .chromium, dataFolder: "com.operasoftware.Opera"),
        Browser(name: "Opera GX", bundleId: "com.operasoftware.OperaGX", family: .chromium, dataFolder: "com.operasoftware.OperaGX"),
        Browser(name: "Ecosia", bundleId: "org.ecosia.browser", family: .chromium, dataFolder: "EcosiaBrowser"),
        Browser(name: "Wavebox", bundleId: "com.bookry.wavebox", family: .chromium, dataFolder: "WaveboxApp"),
        Browser(name: "Yandex", bundleId: "ru.yandex.desktop.yandex-browser", family: .chromium, dataFolder: "Yandex/YandexBrowser"),
        Browser(name: "Firefox", bundleId: "org.mozilla.firefox", family: .firefox, dataFolder: "Firefox"),
        Browser(name: "Firefox Developer Edition", bundleId: "org.mozilla.firefoxdeveloperedition", family: .firefox, dataFolder: "Firefox"),
        Browser(name: "Zen", bundleId: "app.zen-browser.zen", family: .firefox, dataFolder: "zen"),
        Browser(name: "Safari", bundleId: "com.apple.Safari", family: .plain, dataFolder: nil),
        Browser(name: "Arc", bundleId: "company.thebrowser.Browser", family: .plain, dataFolder: nil),
    ]

    public static func known(bundleId: String) -> Browser? { known.first { $0.bundleId == bundleId } }
}

/// A browser profile betterlink can open links in.
public struct BrowserProfile: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// Bundle id of the profile's browser.
    public let browser: String
    /// What the browser needs to pick the profile: the folder name for
    /// Chromium ("Default", "Profile 1"), the profile name for Firefox, and
    /// "" for a browser without profiles.
    public let directory: String
    /// The name shown in betterlink: "Personal", "Work".
    public let name: String
    /// The profile's color as 0xRRGGBB, when the browser records one.
    public let color: UInt32?
    public var id: String { browser + "|" + directory }
    public var ref: ProfileRef { ProfileRef(browser: browser, directory: directory) }

    public init(browser: String = Browser.brave.bundleId, directory: String, name: String, color: UInt32?) {
        self.browser = browser; self.directory = directory; self.name = name; self.color = color
    }

    private enum CodingKeys: String, CodingKey { case browser, directory, name, color }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Before 0.2 betterlink only knew Brave, so a profile without a browser is Brave's.
        browser = try c.decodeIfPresent(String.self, forKey: .browser) ?? Browser.brave.bundleId
        directory = try c.decode(String.self, forKey: .directory)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(UInt32.self, forKey: .color)
    }

    /// Chromium names profile folders "Default" and "Profile <n>". Only those
    /// reach a Chromium browser's command line.
    public static func isValidDirectory(_ d: String) -> Bool {
        d.wholeMatch(of: #/Default|Profile [1-9][0-9]{0,3}/#) != nil
    }

    /// Whether `directory` may reach the command line of a browser in `family`.
    public static func isValid(directory d: String, family: Browser.Family) -> Bool {
        switch family {
        case .chromium: return isValidDirectory(d)
        case .firefox:
            // A Firefox profile name follows -P. It must not look like a switch.
            return !d.isEmpty && d.count <= 100 && !d.hasPrefix("-")
                && d.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F }
        case .plain: return d.isEmpty
        }
    }
}

/// Which browser and profile: what a rule and the fallback point at.
public struct ProfileRef: Codable, Equatable, Hashable, Sendable {
    public let browser: String
    public let directory: String
    public init(browser: String, directory: String) { self.browser = browser; self.directory = directory }

    /// "com.brave.Browser|Profile 1" (the UserDefaults form), or a bare
    /// directory from before 0.2, which was always Brave's.
    public init(stored: String) {
        if let bar = stored.firstIndex(of: "|") {
            browser = String(stored[..<bar]); directory = String(stored[stored.index(after: bar)...])
        } else {
            browser = Browser.brave.bundleId; directory = stored
        }
    }
    public var stored: String { browser + "|" + directory }
}

public struct ProfileCatalog: Equatable, Sendable {
    public let profiles: [BrowserProfile]

    public init(profiles: [BrowserProfile]) { self.profiles = profiles }

    /// Whether there is a real profile to pick (not only Safari or Arc).
    public var hasProfilesToChoose: Bool { profiles.contains { !$0.directory.isEmpty } }

    /// This catalog plus one entry for each installed browser without
    /// profiles (Safari, Arc). Those are never stored: they follow what is installed.
    public func addingPlain(installed: [Browser]) -> ProfileCatalog {
        let real = profiles.filter { !$0.directory.isEmpty }
        let plain = installed.filter { $0.family == .plain }
            .map { BrowserProfile(browser: $0.bundleId, directory: "", name: $0.name, color: nil) }
        return ProfileCatalog(profiles: real + plain)
    }

    /// Names that profiles in more than one browser use.
    public var ambiguousNames: Set<String> {
        var browsers: [String: Set<String>] = [:]
        for p in profiles { browsers[p.name, default: []].insert(p.browser) }
        return Set(browsers.filter { $0.value.count > 1 }.keys)
    }

    /// Names more than one profile uses, in one browser or several: a bare
    /// name like these can't pick a profile.
    public var repeatedNames: Set<String> {
        var count: [String: Int] = [:]
        for p in profiles { count[p.name, default: 0] += 1 }
        return Set(count.filter { $0.value > 1 }.keys)
    }

    /// Whether two profiles in one browser share this name.
    public func isRepeated(_ name: String, in browser: String) -> Bool {
        profiles.filter { $0.name == name && ($0.browser == browser || Browser.known(bundleId: $0.browser)?.name == browser) }.count > 1
    }

    public func profile(_ ref: ProfileRef) -> BrowserProfile? {
        profiles.first { $0.browser == ref.browser && $0.directory == ref.directory }
    }

    /// For config.ts: a profile by its name, optionally within one browser
    /// (by name or bundle id). Nil when there is none, or several.
    public func profile(named name: String, browser: String? = nil) -> BrowserProfile? {
        let matches = profiles.filter { p in
            guard p.name == name else { return false }
            guard let browser else { return true }
            return p.browser == browser || Browser.known(bundleId: p.browser)?.name == browser
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Reads every profile of `browsers` from their files under `home`.
    /// Files that can't be read (absent, or blocked by macOS) contribute nothing.
    public static func load(browsers: [Browser], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> ProfileCatalog {
        ProfileCatalog(profiles: browsers.flatMap { b -> [BrowserProfile] in
            switch b.family {
            case .plain:
                return []   // see addingPlain(installed:)
            case .chromium:
                guard let f = b.profilesFile(home: home), let data = try? Data(contentsOf: f) else { return [] }
                return parse(localStateJSON: data, browser: b.bundleId).profiles
            case .firefox:
                guard let f = b.profilesFile(home: home), let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
                return parse(profilesINI: text, browser: b.bundleId).profiles
            }
        })
    }

    /// The profiles in a Chromium "Local State" file, in the browser's order.
    public static func parse(localStateJSON data: Data, browser: String = Browser.brave.bundleId) -> ProfileCatalog {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return ProfileCatalog(profiles: []) }
        let order = (profile["profiles_order"] as? [String]) ?? []
        let dirs = order.filter { cache[$0] != nil } + cache.keys.sorted().filter { !order.contains($0) }
        let list: [BrowserProfile] = dirs.compactMap { dir in
            guard BrowserProfile.isValidDirectory(dir), let info = cache[dir] as? [String: Any] else { return nil }
            let name = (info["name"] as? String) ?? dir
            // Chromium stores colors as signed 32-bit ARGB.
            let seed = (info["profile_color_seed"] as? NSNumber)?.int64Value
            let color = seed.map { UInt32(truncatingIfNeeded: $0) & 0xFFFFFF }
            return BrowserProfile(browser: browser, directory: dir, name: name, color: color)
        }
        return ProfileCatalog(profiles: list)
    }

    /// The color a Chromium browser paints a profile's window frame with
    /// (`profile_highlight_color` in Local State, signed 32-bit ARGB), as RGB.
    public static func frameColor(localStateJSON data: Data, directory: String) -> UInt32? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = ((root["profile"] as? [String: Any])?["info_cache"] as? [String: Any])?[directory] as? [String: Any],
              let n = (info["profile_highlight_color"] as? NSNumber)?.int64Value else { return nil }
        return UInt32(truncatingIfNeeded: n) & 0xFFFFFF
    }

    /// The color a profile with a custom color theme ("Customize Chrome" ›
    /// a color) paints its frame with, from that profile's Preferences, as RGB.
    /// nil for other themes; `frameColor(localStateJSON:)` covers those.
    public static func themeColor(preferencesJSON data: Data) -> UInt32? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              ((root["extensions"] as? [String: Any])?["theme"] as? [String: Any])?["id"] as? String == "autogenerated_theme_id",
              let n = (((root["autogenerated"] as? [String: Any])?["theme"] as? [String: Any])?["color"] as? NSNumber)?.int64Value
        else { return nil }
        return UInt32(truncatingIfNeeded: n) & 0xFFFFFF
    }

    /// The profiles in a Firefox profiles.ini: each [ProfileN] section's Name.
    public static func parse(profilesINI text: String, browser: String) -> ProfileCatalog {
        var list: [BrowserProfile] = []
        var inProfile = false
        func flush(_ name: String?) {
            if let name, BrowserProfile.isValid(directory: name, family: .firefox), !list.contains(where: { $0.directory == name }) {
                list.append(BrowserProfile(browser: browser, directory: name, name: name, color: nil))
            }
        }
        var name: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if inProfile { flush(name) }
                inProfile = line.wholeMatch(of: #/\[Profile[0-9]+\]/#) != nil
                name = nil
            } else if inProfile, line.hasPrefix("Name=") {
                name = String(line.dropFirst(5))
            }
        }
        if inProfile { flush(name) }
        return ProfileCatalog(profiles: list)
    }
}
