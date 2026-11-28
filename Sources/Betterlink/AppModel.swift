import AppKit
import BetterlinkCore
import Combine
import ServiceManagement
import UniformTypeIdentifiers

/// Everything the window shows, and the routing of each link.
@MainActor
final class AppModel: ObservableObject {
    enum ConfigStatus: Equatable {
        case absent
        case loading
        case loaded(Date)
        /// `usingPrevious`: an earlier version of config.ts loaded fine and is still in use.
        case failed(String, usingPrevious: Bool)
    }

    /// Browsers betterlink knows that are installed on this Mac.
    @Published private(set) var browsers: [Browser] = []
    /// Where rules.json and config.ts live (Settings › Settings folder).
    @Published private(set) var paths = SettingsFolder.resolve()
    var store: RuleStore { RuleStore(folder: paths) }
    /// True when BETTERLINK_HOME picks the folder, so the window can't change it.
    let folderFromEnvironment = !(ProcessInfo.processInfo.environment["BETTERLINK_HOME"] ?? "").isEmpty

    @Published private(set) var rules: [Rule] = []
    /// "Holding ⌃⌘ opens links in Work" (Link Rules › Modifier keys).
    @Published private(set) var modifierRules: [ModifierRule] = []
    @Published private(set) var rulesError: String?
    @Published private(set) var catalog = ProfileCatalog(profiles: [])
    @Published private(set) var configStatus: ConfigStatus = .loading
    @Published private(set) var log = LogBuffer()
    @Published private(set) var launchError: String?
    @Published private(set) var isDefaultBrowser = false
    /// Whether betterlink can read each installed browser's profile list
    /// (macOS asks the user before an app reads another app's data).
    @Published private(set) var browserAccess: [String: ProfileFileAccess] = [:]
    /// Whether betterlink has Full Disk Access; nil when it can't tell.
    @Published private(set) var fullDiskAccess: Bool?
    @Published private(set) var opensAtLogin = false
    /// Whether the Log page shows. Stored in rules.json (so the CLI and a
    /// synced folder carry it); changing it here saves it there.
    @Published var showLog: Bool = false {
        didSet { if !applyingFromDisk && showLog != oldValue { save(note: "Log \(showLog ? "shown" : "hidden").") { $0.showLog = showLog } } }
    }
    /// Whether the menu bar icon shows. Per Mac (UserDefaults, see
    /// MenuBarIcon), not rules.json; the app delegate adds or removes it.
    @Published var showsMenuBarIcon: Bool = MenuBarIcon.isShown(in: MenuBarIcon.defaults()) {
        didSet {
            guard showsMenuBarIcon != oldValue else { return }
            MenuBarIcon.setShown(showsMenuBarIcon, in: MenuBarIcon.defaults())
            note(showsMenuBarIcon ? "Menu bar icon shown." : "Menu bar icon hidden. Open betterlink from Spotlight or Finder to get back here.")
        }
    }
    /// Whether a small toast says which profile a rule chose. Per Mac
    /// (UserDefaults, see LinkToast), like the menu bar icon.
    @Published var showsLinkToast: Bool = LinkToast.isShown(in: MenuBarIcon.defaults()) {
        didSet {
            guard showsLinkToast != oldValue else { return }
            LinkToast.setShown(showsLinkToast, in: MenuBarIcon.defaults())
            note(showsLinkToast ? "Link toast turned on." : "Link toast turned off.")
        }
    }
    @Published var linkToastPosition: LinkToast.Position = LinkToast.position(in: MenuBarIcon.defaults()) {
        didSet {
            guard linkToastPosition != oldValue else { return }
            LinkToast.setPosition(linkToastPosition, in: MenuBarIcon.defaults())
        }
    }
    /// How large betterlink draws its text, in the window and in the sidebar.
    /// Per Mac (UserDefaults, see TextSize), like the link toast. Views read it
    /// through the design tokens (TextScale), so a new size shows at once.
    @Published var textSize: TextSize = TextSize.current(in: MenuBarIcon.defaults()) {
        didSet {
            guard textSize != oldValue else { return }
            TextSize.set(textSize, in: MenuBarIcon.defaults())
            TextScale.shared.set(textSize)
            note("Text size set to \(textSize.label).")
        }
    }
    /// Where links no rule claims open. Stored in rules.json; changing it
    /// here saves it there.
    @Published var fallback: ProfileRef = ProfileRef(browser: Browser.brave.bundleId, directory: "Default") {
        didSet { if !applyingFromDisk && fallback != oldValue { save(note: "Fallback changed.") { $0.fallback = fallback } } }
    }
    /// True while values read from rules.json are being applied, so applying
    /// them doesn't write them back.
    private var applyingFromDisk = false

    private var script: ConfigScript?
    private var compiler: TypeScriptCompiler?
    private var configSource: String?
    /// The last config.ts failure logged, so retries don't repeat it.
    private var lastConfigFailure: String?
    /// Modification dates of the browsers' profile files last merged in.
    private var profileFileDates: [String: Date] = [:]
    /// The settings folder is watched for files being replaced or added;
    /// rules.json and config.ts are each watched too, because chmod and
    /// editors that save in place change a file without touching the folder.
    /// The file watchers are re-armed on each reload.
    private var dirWatcher: PathWatcher?
    private var rulesWatcher: PathWatcher?
    private var fileWatcher: PathWatcher?
    /// Links that arrive before config.ts has loaded for the first time wait
    /// for it, so config.ts always gets the first say.
    private var waiting: [(String, String?, ModifierKeys)] = []
    private var initialLoadDone = false

    init() {
        // Before anything is drawn: the window and the sidebars read it.
        TextScale.shared.set(textSize)
        browsers = Self.installedBrowsers()
        migrateDefaultsIntoRulesJSON()
        reloadRules()
        refreshCatalog()
        refreshDefaultBrowser()
    }

    var router: Router {
        Router(rules: rules, modifierRules: modifierRules, script: script, catalog: catalog, fallback: fallback,
               installed: Set(browsers.map(\.bundleId)))
    }

    /// Whether this Mac has the profile: betterlink knows it and its browser is installed.
    func has(_ ref: ProfileRef) -> Bool {
        catalog.profile(ref) != nil && browsers.contains { $0.bundleId == ref.browser }
    }

    /// The profile a rule belongs to on the Link Rules page: the first of its
    /// profiles this Mac has (where its links open here), else its first choice.
    var ruleKey: RuleGroups.Key {
        let catalog = catalog, installed = Set(browsers.map(\.bundleId))
        return RuleGroups.opensIn { catalog.profile($0) != nil && installed.contains($0.browser) }
    }
    var fallbackProfile: BrowserProfile? { catalog.profile(fallback) }

    static func installedBrowsers() -> [Browser] {
        Browser.known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleId) != nil }
    }

    func browserName(_ bundleId: String) -> String { Browser.known(bundleId: bundleId)?.name ?? bundleId }

    // MARK: Routing

    /// - Parameter modifiers: the modifier keys held as the link arrived.
    func open(_ raw: String, opener: String?, modifiers: ModifierKeys = []) {
        guard initialLoadDone else { waiting.append((raw, opener, modifiers)); return }
        refreshCatalog()
        let decision = router.decide(raw, opener: opener, modifiers: modifiers)
        switch decision.action {
        case .refuse:
            record(raw, opener, nil, decision.reason)
        case .open(let profile, let argument):
            switch LaunchPlan.make(profile: profile, argument: argument, catalog: catalog,
                                   fallback: fallback, ownBundleId: Bundle.main.bundleIdentifier ?? "") {
            case .success(let plan):
                record(raw, opener, profile.name, decision.reason)
                launch(plan, ifSwitchFails: plan.afterFailedSwitch(fallback: fallback, catalog: catalog,
                                                                    ownBundleId: Bundle.main.bundleIdentifier ?? ""))
                if showsLinkToast, let m = LinkToast.message(for: decision) {
                    LinkToastWindow.shared.show(profile: m.profile, detail: m.detail, position: linkToastPosition)
                }
            case .failure(let f):
                record(raw, opener, nil, "Not opened: \(f).")
                fail("Couldn't open a link: \(f). Is \(browserName(profile.browser)) installed with that profile?")
            }
        }
    }

    /// What would happen to a link, without opening it (the link tester).
    func preview(_ raw: String, modifiers: ModifierKeys = []) -> Decision { router.decide(raw, opener: nil, modifiers: modifiers) }

    /// - Parameter ifSwitchFails: for a Dia link, the plan that opens it in
    ///   the fallback profile when Dia can't show the link's space
    ///   (`LaunchPlan.afterFailedSwitch`); nil when there is no other place.
    private func launch(_ plan: LaunchPlan, ifSwitchFails: LaunchPlan? = nil) {
        let name = browserName(plan.bundleId)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: plan.bundleId) else {
            // Never hand the link to the system: betterlink is the default
            // browser, so it would come straight back here.
            fail("\(name) isn't installed, so the link wasn't opened.")
            return
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        let done: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { _, error in
            guard let error else { return }
            Task { @MainActor in self.fail("\(name) didn't open: \(error.localizedDescription)") }
        }
        switch plan.mode {
        case .commandLine(let args):
            cfg.arguments = args
            // A running Chromium browser honours --profile-directory only when
            // the link comes on a fresh command line; the new process hands
            // both to the running one and exits. Firefox does the same for a
            // profile that is already running.
            cfg.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: app, configuration: cfg, completionHandler: done)
        case .openURL(let link):
            guard let url = URL(string: link) else { fail("Couldn't open \(link) in \(name)."); return }
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: cfg, completionHandler: done)
        case .switchSpace(let space, let link):
            // Dia refuses a second process, so never createsNewApplicationInstance
            // here: switch its front window to the space, then hand it the link.
            // When the switch fails, Dia would open the link in whichever space
            // is in front, which may be another profile. So the link goes to the
            // fallback profile instead; only a link that was headed for the
            // fallback already (no `ifSwitchFails`) is still handed to Dia.
            guard let url = URL(string: link) else { fail("Couldn't open \(link) in \(name)."); return }
            // One Dia link at a time: switch the space, hand Dia the link, and
            // only then let the next link switch the space again. Otherwise two
            // links clicked close together can both open in the second space.
            Self.diaQueue.async {
                let outcome = Self.runOsascript(DiaSpace.osascriptArguments(space: space))
                let handedOver = DispatchSemaphore(value: 0)
                Task { @MainActor in
                    if !outcome.switched, let other = ifSwitchFails {
                        let elsewhere = self.fallbackProfile
                            ?? BrowserProfile(browser: other.bundleId, directory: self.fallback.directory,
                                              name: self.browserName(other.bundleId), color: nil)
                        if let line = outcome.note(space: space, openedIn: elsewhere.name) { self.note(line) }
                        // Replaces the toast that named the space the link didn't reach.
                        if self.showsLinkToast {
                            LinkToastWindow.shared.show(profile: elsewhere, detail: "Dia couldn't switch to \(space)",
                                                        position: self.linkToastPosition)
                        }
                        // A fallback that is another Dia space waits its turn
                        // on this queue; if that switch fails too, Dia gets the link.
                        self.launch(other)
                        handedOver.signal()
                        return
                    }
                    if let line = outcome.note(space: space) { self.note(line) }
                    let open = NSWorkspace.OpenConfiguration()
                    open.activates = true
                    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: open) { running, error in
                        done(running, error)
                        handedOver.signal()
                    }
                }
                _ = handedOver.wait(timeout: .now() + 5)
                // Dia reads the link after the open call returns; give it a
                // moment before the next link moves the window to another space.
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    /// Dia links are opened one after another on this queue (see `launch`).
    private static let diaQueue = DispatchQueue(label: "betterlink.dia-space")

    /// Runs /usr/bin/osascript with `arguments`, waiting at most 10 s.
    private nonisolated static func runOsascript(_ arguments: [String]) -> DiaSpace.Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        do { try p.run() } catch { return .failed(error.localizedDescription) }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if p.isRunning { p.terminate(); return .failed("timed out") }
        let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return DiaSpace.Outcome.parse(status: p.terminationStatus, output: o, error: e)
    }

    private func record(_ link: String, _ opener: String?, _ profile: String?, _ message: String) {
        log.append(link: link, opener: opener, profileName: profile, message: message)
    }

    private func note(_ message: String) { log.append(link: nil, opener: nil, profileName: nil, message: message) }

    private func fail(_ message: String) {
        launchError = message
        note(message)
        NotificationCenter.default.post(name: .betterlinkNeedsAttention, object: nil)
    }

    func clearLaunchError() { launchError = nil }

    /// Shows the toast as a matched link would (General › Link toast › Preview).
    func previewLinkToast() {
        let p = catalog.profiles.first { !$0.directory.isEmpty } ?? fallbackProfile
            ?? BrowserProfile(browser: fallback.browser, directory: fallback.directory, name: "Work", color: nil)
        LinkToastWindow.shared.show(profile: p, detail: "Rule 1", position: linkToastPosition)
    }
    func clearLog() { log.clear() }

    // MARK: Rules and profiles

    /// Before 0.2 the fallback and the log switch lived in the app's
    /// preferences; they now live in rules.json. Moves them once.
    private func migrateDefaultsIntoRulesJSON() {
        // A run on another folder (BETTERLINK_HOME, for tests) must not move
        // the app's own preferences into it.
        guard !folderFromEnvironment else { return }
        let d = UserDefaults.standard
        let oldFallback = d.string(forKey: "fallbackProfile").map(ProfileRef.init(stored:))
        let oldShowLog = d.object(forKey: "showLog") as? Bool
        guard oldFallback != nil || oldShowLog != nil else { return }
        do {
            var moved = false
            try store.update { c in
                if c.fallback == nil, let oldFallback { c.fallback = oldFallback; moved = true }
                if c.showLog == nil, let oldShowLog { c.showLog = oldShowLog; moved = true }
                // A file that already has both (another Mac's, synced) wins.
                if c.fallback != nil && c.showLog != nil { moved = true }
            }
            if moved {
                d.removeObject(forKey: "fallbackProfile")
                d.removeObject(forKey: "showLog")
            }
        } catch {
            note("Couldn't move the fallback into rules.json: \(error)")
        }
    }

    /// The last rules.json read, so a browser installed later can take back
    /// the fallback that names it.
    private var lastContents: RuleStore.Contents?

    private func apply(_ c: RuleStore.Contents) {
        lastContents = c
        applyingFromDisk = true
        defer { applyingFromDisk = false }
        rules = c.rules
        modifierRules = c.modifierRules ?? []
        fallback = Agent.effectiveFallback(c.fallback, installed: browsers)
        showLog = c.showLog ?? false
        setCatalog(ProfileCatalog(profiles: c.profiles ?? []))
    }

    /// Reads rules.json again. Called at launch and whenever its folder
    /// changes, so `--import-profiles` run elsewhere shows up at once. When
    /// the file doesn't load, routing uses no rules (every link goes to the
    /// fallback profile) and saving is refused until it is fixed.
    func reloadRules() {
        rulesWatcher = PathWatcher(url: store.file) { [weak self] in
            Task { @MainActor in self?.reloadRules() }
        }
        SyncController.shared.localChanged()
        do {
            apply(try store.load())
            rulesError = nil
        } catch {
            rules = []
            modifierRules = []
            // No stored fallback while the file is broken, so a browser
            // change re-picks this Mac's default rather than the old value.
            lastContents = nil
            // rules.json holds the chosen fallback; without it, use the
            // default for this Mac so links still open somewhere real.
            applyingFromDisk = true
            fallback = Agent.effectiveFallback(nil, installed: browsers)
            applyingFromDisk = false
            rulesError = "\(error). Fix or delete \(store.file.path); until then every link opens in the fallback profile and changes can't be saved."
        }
    }

    // A sheet saves what it changed since it opened (`base`), merged into
    // what is on disk now (ListMerge), so a rule the CLI or another Mac added
    // meanwhile is kept.

    func saveRules(_ new: [Rule], from base: [Rule]) {
        save(note: "Link Rules saved.") { $0.rules = ListMerge.merge(base: base, mine: new, theirs: $0.rules) }
    }

    /// Moves a rule to just above another, by id, in the rules on disk now.
    func moveRule(_ id: UUID, above other: UUID) {
        save(note: "Rule moved.") { c in
            guard let from = c.rules.firstIndex(where: { $0.id == id }) else { return }
            let r = c.rules.remove(at: from)
            let to = c.rules.firstIndex(where: { $0.id == other }) ?? from
            c.rules.insert(r, at: to)
        }
    }

    func saveModifierRules(_ new: [ModifierRule], from base: [ModifierRule]) {
        save(note: "Modifier keys saved.") {
            let merged = ListMerge.merge(base: base, mine: new, theirs: $0.modifierRules ?? [])
            $0.modifierRules = merged.isEmpty ? nil : merged
        }
    }

    func saveProfiles(_ new: [BrowserProfile], from base: [BrowserProfile]) {
        let real = new.filter { !$0.directory.isEmpty }
        save(note: "Profiles saved.") {
            $0.profiles = ListMerge.merge(base: base.filter { !$0.directory.isEmpty }, mine: real, theirs: $0.profiles ?? [])
        }
    }

    /// Every save changes only its own part of what is on disk now, and
    /// writes nothing when the file doesn't load.
    private func save(note message: String, _ change: (inout RuleStore.Contents) throws -> Void) {
        do {
            apply(try store.update(change))
            rulesError = nil
            note(message)
        } catch {
            // Show why, then show what is really on disk.
            launchError = "Not saved: \(error)"
            reloadRules()
        }
    }

    /// Reads each installed browser's profile list and merges it into the
    /// saved one. macOS usually blocks reading another app's files until the
    /// user allows it (see Permissions), so for a browser it can't read, the
    /// saved profiles stay as they are. Browsers without profiles (Safari,
    /// Arc) are always listed.
    func refreshCatalog() {
        let installed = Self.installedBrowsers()
        if installed != browsers {
            browsers = installed
            setCatalog(ProfileCatalog(profiles: catalog.profiles))
            applyingFromDisk = true
            fallback = Agent.effectiveFallback(lastContents?.fallback, installed: browsers)
            applyingFromDisk = false
        }
        var merged = catalog.profiles.filter { !$0.directory.isEmpty }
        var seen: [String: Date] = [:]
        var changed = false
        // Each browser read, with its profiles now: saved by replacing only
        // that browser's entries in what is on disk at save time.
        var refreshed: [String: [BrowserProfile]] = [:]
        for b in browsers {
            switch b.family {
            case .plain:
                continue   // listed from what is installed, never stored
            case .chromium, .firefox:
                guard let file = b.profilesFile(),
                      let date = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
                      date != profileFileDates[file.path] else { continue }
                let live = ProfileCatalog.load(browsers: [b]).profiles
                guard !live.isEmpty else { continue }   // unreadable: keep the saved ones, try again next time
                seen[file.path] = date
                // A Firefox family may share one profiles.ini; keep each browser's own entries.
                let others = merged.filter { $0.browser != b.bundleId }
                let next = others + live
                refreshed[b.bundleId] = live
                if Set(next) != Set(merged) { merged = next; changed = true }
            }
        }
        if changed {
            // Only remember a file's version once it is saved, so a refused
            // save (rules.json doesn't load) is retried on the next check.
            guard rulesError == nil else { return }
            save(note: "Profiles updated from the browsers.") { contents in
                var list = contents.profiles ?? []
                for (bundleId, live) in refreshed { list = list.filter { $0.browser != bundleId } + live }
                contents.profiles = list
            }
            guard rulesError == nil else { return }
        }
        profileFileDates.merge(seen) { $1 }
    }

    private func setCatalog(_ stored: ProfileCatalog) {
        let new = stored.addingPlain(installed: browsers)
        guard new != catalog else { return }
        let hadProfiles = !catalog.profiles.isEmpty
        catalog = new
        try? ConfigLoader.writeEditorSupport(paths: paths, catalog: new)
        // Profile names are part of config.ts's types.
        if hadProfiles { reloadConfig(force: true) }
    }

    // MARK: config.ts

    /// The CLI changed something: re-read the settings folder pointer,
    /// rules.json and config.ts. The notice itself carries nothing.
    private var reloadObserver: NSObjectProtocol?
    func listenForCLIChanges() {
        reloadObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentCommand.reloadNotice, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let folder = SettingsFolder.resolve()
                if folder != self.paths { self.adoptFolder(folder) }
                self.reloadRules()
                self.reloadConfig(force: true)
                SidebarLibraryModel.shared.reload()
                // `betterlink sidebar settings set` writes the sidebar's settings.
                SidebarController.shared.reloadSettings()
                // `betterlink tabs setup` and `betterlink sync set` write theirs too.
                TabsModel.shared.registrationChanged()
                SyncController.shared.reloadSettings()
                self.refreshPermissions()
                // `betterlink menu-bar set` writes the setting from another process.
                let shown = MenuBarIcon.isShown(in: MenuBarIcon.defaults())
                if shown != self.showsMenuBarIcon { self.showsMenuBarIcon = shown }
                Updater.shared.reloadSetting()
                // So does `betterlink toast set`.
                let toast = LinkToast.isShown(in: MenuBarIcon.defaults())
                if toast != self.showsLinkToast { self.showsLinkToast = toast }
                let where_ = LinkToast.position(in: MenuBarIcon.defaults())
                if where_ != self.linkToastPosition { self.linkToastPosition = where_ }
                // And `betterlink text-size set`.
                let size = TextSize.current(in: MenuBarIcon.defaults())
                if size != self.textSize { self.textSize = size }
                // `betterlink tour …` changed what was seen, or asked for the tour.
                TourModel.shared.reload()
            }
        }
    }

    func startConfig(resourceDirectory: URL) {
        defer { SyncController.shared.attach(settings: paths, note: { [weak self] in self?.note($0) }) }
        if paths.directory == SettingsFolder.defaultDirectory {
            do {
                if try paths.adoptLegacyConfig() { note("Copied config.ts here from ~/.config/betterlink (the old copy is untouched).") }
            } catch {
                // Say so: otherwise the user's routing code would silently stop running.
                fail("Your config.ts in ~/.config/betterlink wasn't moved to the settings folder, so it isn't running: \(error) "
                     + "Fix it and relaunch betterlink, or copy it to \(paths.configFile.path) yourself.")
            }
        }
        watchFolder()
        let tsDir = resourceDirectory.appendingPathComponent("typescript")
        Task.detached(priority: .userInitiated) {
            let c = try? TypeScriptCompiler(typescriptJS: tsDir.appendingPathComponent("typescript.js"),
                                            libDirectory: tsDir.appendingPathComponent("lib"))
            await MainActor.run {
                self.compiler = c
                if c == nil { self.note("The bundled TypeScript compiler failed to load; config.ts is ignored.") }
                self.reloadConfig(force: true)
            }
        }
        // Never hold links for long, even if the compiler hangs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.finishInitialLoad() }
    }

    private func watchFolder() {
        try? FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? ConfigLoader.writeEditorSupport(paths: paths, catalog: catalog)
        dirWatcher = PathWatcher(url: paths.directory) { [weak self] in
            Task { @MainActor in
                PerfTrace.mark("settings folder changed")
                PerfTrace.span("reloadRules") { self?.reloadRules() }
                PerfTrace.span("reloadConfig") { self?.reloadConfig() }
                SidebarLibraryModel.shared.reload()
            }
        }
    }

    /// Switches to another settings folder, copying rules.json and config.ts
    /// there when it has none. The old folder is left as it is.
    func useSettingsFolder(_ url: URL?) {
        let target = url.map { SettingsFolder(directory: $0) } ?? SettingsFolder(directory: SettingsFolder.defaultDirectory)
        guard target != paths else { return }
        do {
            try paths.copySettings(to: target)
        } catch {
            launchError = "Didn't switch folders: \(error)"
            return
        }
        if let url { UserDefaults.standard.set(url.path, forKey: SettingsFolder.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: SettingsFolder.defaultsKey) }
        adoptFolder(target)
    }

    private func adoptFolder(_ target: SettingsFolder) {
        paths = target
        note("Settings folder is now \(target.directory.path).")
        SyncController.shared.attach(settings: target, note: { [weak self] in self?.note($0) })
        watchFolder()
        reloadRules()
        reloadConfig(force: true)
        SidebarLibraryModel.shared.reload(folder: target)
    }

    func revealSettingsFolder() { NSWorkspace.shared.activateFileViewerSelecting([paths.directory]) }

    /// Counts config.ts loads, so a late one is dropped (see `reloadConfig`).
    private var configGeneration = 0

    func reloadConfig(force: Bool = false) {
        fileWatcher = PathWatcher(url: paths.configFile) { [weak self] in
            Task { @MainActor in self?.reloadConfig() }
        }
        SyncController.shared.localChanged()
        guard let compiler else { finishInitialLoad(); return }
        let source = try? String(contentsOf: paths.configFile, encoding: .utf8)
        // Same text and it loaded: nothing to do. After a failure, check again
        // even if the text is the same: the fix may have been a chmod.
        var lastFailed = false
        if case .failed = configStatus { lastFailed = true }
        if !force && !lastFailed && source == configSource && initialLoadDone { return }
        configSource = source
        configStatus = .loading
        // Only the newest load may apply: an older compile that finishes
        // late must not bring back a config.ts that was changed or deleted.
        configGeneration += 1
        let generation = configGeneration
        let paths = paths, catalog = catalog
        let logLine: @Sendable (String) -> Void = { line in
            Task { @MainActor in self.note("config.ts: \(line)") }
        }
        Task.detached(priority: .userInitiated) {
            let result = ConfigLoader.load(paths: paths, compiler: compiler, catalog: catalog, log: logLine)
            await MainActor.run {
                guard generation == self.configGeneration else { return }
                self.apply(result)
            }
        }
    }

    private func apply(_ result: ConfigLoadResult) {
        switch result {
        case .absent:
            script = nil
            configStatus = .absent
            lastConfigFailure = nil
        case .loaded(let s):
            script = s
            configStatus = .loaded(Date())
            lastConfigFailure = nil
            note("config.ts loaded.")
        case .failed(let e):
            // Keep the last version that loaded; never route with a broken one.
            configStatus = .failed(e.description, usingPrevious: script != nil)
            // After a failure every change in the folder retries the load (the
            // fix may be a chmod), so log a failure only when it is new.
            if e.description != lastConfigFailure { note("config.ts not loaded: \(e.description)") }
            lastConfigFailure = e.description
        }
        finishInitialLoad()
    }

    private func finishInitialLoad() {
        guard !initialLoadDone else { return }
        initialLoadDone = true
        let queued = waiting; waiting = []
        for (raw, opener, modifiers) in queued { open(raw, opener: opener, modifiers: modifiers) }
    }

    /// Opens config.ts in the user's editor, creating the starter file first.
    func editConfig() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: paths.configFile.path) {
            try? ConfigLoader.writeEditorSupport(paths: paths, catalog: catalog)
            fm.createFile(atPath: paths.configFile.path, contents: Data(ConfigLoader.starterConfig.utf8),
                          attributes: [.posixPermissions: 0o600])
        }
        NSWorkspace.shared.open(paths.configFile)
    }

    func revealConfig() { NSWorkspace.shared.activateFileViewerSelecting([paths.configFile]) }

    // MARK: Default browser

    func refreshDefaultBrowser() {
        isDefaultBrowser = AgentCommand.isDefaultBrowser()
    }

    // MARK: Command line

    /// The command inside this app, and where Install Command links it.
    var bundledCommand: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/betterlink") }
    var commandLink: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/betterlink") }
    private var command: CommandLink { CommandLink(link: commandLink, bundled: bundledCommand) }
    @Published private(set) var commandInstall: CommandLink.Status = .notInstalled

    func refreshCommandInstall() { commandInstall = command.status() }

    /// Links the bundled command into ~/.local/bin (rules in CommandLink).
    func installCommand() {
        do {
            try command.install()
            note("Installed the betterlink command at \(commandLink.path).")
        } catch {
            launchError = "Couldn't install the command: \(error.localizedDescription)"
        }
        refreshCommandInstall()
    }

    func uninstallCommand() {
        do {
            try command.uninstall()
        } catch {
            launchError = "Couldn't uninstall the command: \(error.localizedDescription)"
        }
        refreshCommandInstall()
    }

    /// The prompt the Agents page offers to copy: everything an agent needs
    /// to start, with the command's full path so it works even when
    /// ~/.local/bin isn't on the agent's PATH.
    var agentPrompt: String {
        """
        I use **betterlink**, a Mac app that opens each link I click in the right browser and profile. Help me customize it with its command-line tool, `\(commandLink.path)`. Below I call it `betterlink`; use that full path if `betterlink` isn't on your PATH.

        - Run `betterlink --llms` to see every command, and add `--help` to any command for its options.
        - Start with `betterlink status`, `betterlink profiles list` and `betterlink rules list` to see my setup.
        - Ask me which sites should open in which browser and profile. Then add rules with `betterlink rules add` and check each one with `betterlink test <link>`.
        - To open a link in a profile by holding keys while clicking it (such as ⌃⌘ for Work), use `betterlink keys add` and check with `betterlink test <link> --keys control,command`.
        - For anything Link Rules can't express, write TypeScript in config.ts (`betterlink config path`) and run `betterlink config check` after every edit.
        - Changes show up in betterlink right away. Don't change my default browser or Open at login unless I ask.
        """
    }

    // MARK: Permissions

    /// True when something on the Permissions page needs the user.
    var permissionsNeedAttention: Bool {
        !isDefaultBrowser || browserAccess.values.contains { $0 != .readable && $0 != .missing } && !catalog.hasProfilesToChoose
    }

    /// Re-checks every permission the Permissions page shows.
    func refreshPermissions() {
        refreshDefaultBrowser()
        var access: [String: ProfileFileAccess] = [:]
        for b in browsers where b.family != .plain {
            guard let file = b.profilesFile() else { continue }
            access[b.bundleId] = ProfileFileAccess.check(file)
        }
        browserAccess = access
        fullDiskAccess = FullDiskAccess.isGranted()
        opensAtLogin = SMAppService.mainApp.status == .enabled
        refreshCatalog()
    }

    /// Opens System Settings at Privacy & Security › Full Disk Access, the
    /// grant that lets betterlink read every browser's profile list.
    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            launchError = "Couldn't change Open at login: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    func makeDefaultBrowser() {
        let me = Bundle.main.bundleURL
        // macOS asks the user to confirm, once.
        NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "http") { _ in
            Task { @MainActor in
                NSWorkspace.shared.setDefaultApplication(at: me, toOpenURLsWithScheme: "https") { _ in
                    Task { @MainActor in
                        NSWorkspace.shared.setDefaultApplication(at: me, toOpen: .html) { _ in
                            Task { @MainActor in self.refreshDefaultBrowser() }
                        }
                    }
                }
            }
        }
    }
}

extension Notification.Name {
    static let betterlinkNeedsAttention = Notification.Name("betterlinkNeedsAttention")
    /// Shows a page of betterlink's window; the object is the page's raw value.
    static let betterlinkOpenPage = Notification.Name("betterlinkOpenPage")
}
