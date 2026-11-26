// Generated from Tour/tour.json by scripts/gen-tour.py. Do not edit.
// Change the steps there and run `make tour`.

// The names the steps use. The app draws each control, reads each status and
// colours each tile with a switch over these, so a name the app doesn't know
// yet stops the build instead of showing an empty step.

/// What a step gives the person to act on: a button, a switch, a small form.
public enum TourControl: String, CaseIterable, Sendable {
    case makeDefaultBrowser
    case browserData
    case fallbackPicker
    case firstRule
    case editKeys
    case linkToast
    case showLog
    case menuBarIcon
    case openAtLogin
    case sidebarBrowsers
    case showExtension
    case allowAccessibility
    case showSidebar
    case chooseSyncFolder
    case installCommand
    case askDiaAutomation
    case createConfig
    case automaticUpdates
}

/// What a step shows as done or not yet: a permission, a setting, a connection.
public enum TourProbe: String, CaseIterable, Sendable {
    case defaultBrowser
    case browserData
    case openAtLogin
    case tabsHelper
    case tabsExtension
    case accessibility
    case sidebar
    case syncFolder
    case command
    case automationDia
    case config
}

/// What this Mac needs for a step to apply.
public enum TourCondition: String, CaseIterable, Sendable {
    case sidebarBrowser
    case dia
}

/// The colour behind a topic's symbol, by its name in Design/tokens.json.
public enum TourTile: String, CaseIterable, Sendable {
    case accent
    case success
    case coral
    case tileInk
    case tileNeutral
    case tileTeal
    case tileViolet
}

public enum TourRegistry {
    /// Every topic and step, in the order the tour shows them.
    public static let topics: [TourTopic] = [
        TourTopic(id: "welcome", title: "Welcome",
                  summary: "What betterlink does.",
                  symbol: "arrow.triangle.branch", tile: .accent, tier: .essential, page: nil, steps: [
            TourStep(id: "welcome", revision: 1,
                     title: "Every link, in the right browser and profile",
                     body: "betterlink sits between a click and your browsers. It reads each link you open in any app and sends it to the browser and profile you chose for it. This tour takes about two minutes, and every step can be skipped.",
                     changed: nil, symbol: "arrow.triangle.branch",
                     status: nil, control: nil, requires: nil,
                     cli: nil, cliWhy: nil),
        ]),
        TourTopic(id: "default-browser", title: "Default browser",
                  summary: "Links you click come to betterlink first.",
                  symbol: "globe", tile: .success, tier: .essential, page: "permissions", steps: [
            TourStep(id: "default-browser", revision: 1,
                     title: "Make betterlink your default browser",
                     body: "macOS sends every link you click to the default browser. Once that is betterlink, it passes each one on to the right profile. macOS asks you to confirm the change.",
                     changed: nil, symbol: "globe",
                     status: .defaultBrowser, control: .makeDefaultBrowser, requires: nil,
                     cli: "betterlink default-browser set", cliWhy: nil),
        ]),
        TourTopic(id: "profiles", title: "Profiles",
                  summary: "The browser profiles links can open in.",
                  symbol: "person.2.fill", tile: .coral, tier: .essential, page: "profiles", steps: [
            TourStep(id: "profiles", revision: 1,
                     title: "Find your browser profiles",
                     body: "betterlink opens links in the profiles your browsers already have, and reads each browser's list by itself. If a browser shows as not allowed, turn on Full Disk Access for betterlink in Privacy Settings, or add its profiles by hand under Profiles.",
                     changed: nil, symbol: "person.2.fill",
                     status: .browserData, control: .browserData, requires: nil,
                     cli: "betterlink profiles import", cliWhy: nil),
        ]),
        TourTopic(id: "fallback", title: "Fallback profile",
                  summary: "Where links that match no rule open.",
                  symbol: "arrow.turn.down.right", tile: .accent, tier: .essential, page: "rules", steps: [
            TourStep(id: "fallback", revision: 1,
                     title: "Choose where everything else opens",
                     body: "Links that match no rule open in one profile, your fallback. Pick the profile you use most. You can change it any time at the bottom of Link Rules.",
                     changed: nil, symbol: "arrow.turn.down.right",
                     status: nil, control: .fallbackPicker, requires: nil,
                     cli: "betterlink fallback set --profile Personal", cliWhy: nil),
        ]),
        TourTopic(id: "link-rules", title: "Link Rules",
                  summary: "Send a site to a profile.",
                  symbol: "arrow.triangle.branch", tile: .accent, tier: .essential, page: "rules", steps: [
            TourStep(id: "link-rules", revision: 2,
                     title: "Send a site to a profile",
                     body: "A Link Rule reads \"Open domains matching example.com in Work\". Rules are checked top to bottom and the first match wins. Add one now, or later under Link Rules, which lists your rules by profile and can test any link.",
                     changed: "Link Rules now lists the profiles that have rules. Click one to see and edit only its rules, with a note wherever a rule for another profile is checked first.", symbol: "arrow.triangle.branch",
                     status: nil, control: .firstRule, requires: nil,
                     cli: "betterlink rules add --kind domain --pattern example.com --profile Work", cliWhy: nil),
        ]),
        TourTopic(id: "modifier-keys", title: "Modifier keys",
                  summary: "Hold keys while you click to pick a profile for one link.",
                  symbol: "command", tile: .tileInk, tier: .more, page: "rules", steps: [
            TourStep(id: "modifier-keys", revision: 1,
                     title: "Hold keys to pick a profile for one click",
                     body: "Hold a combination such as ⌃⌘ while you click a link, and it opens in the profile you gave those keys, whatever the rules say. Keep holding until the browser comes forward.",
                     changed: nil, symbol: "command",
                     status: nil, control: .editKeys, requires: nil,
                     cli: "betterlink keys add --keys control,command --profile Work", cliWhy: nil),
        ]),
        TourTopic(id: "feedback", title: "See where links go",
                  summary: "A toast for each routed link, and a log of every one.",
                  symbol: "text.bubble.fill", tile: .tileNeutral, tier: .more, page: "general", steps: [
            TourStep(id: "link-toast", revision: 1,
                     title: "A toast says what chose the profile",
                     body: "When held keys, config.ts or a Link Rule picks the profile, a small badge names the profile and what chose it, then fades. Links that open in the fallback show none.",
                     changed: nil, symbol: "text.bubble.fill",
                     status: nil, control: .linkToast, requires: nil,
                     cli: "betterlink toast set --shown on --position top", cliWhy: nil),
            TourStep(id: "log", revision: 1,
                     title: "The Log shows every link, and why",
                     body: "Turn on the Log page to see each link, where it went and what sent it there. The log is kept in memory only and cleared when betterlink quits.",
                     changed: nil, symbol: "text.bubble.fill",
                     status: nil, control: .showLog, requires: nil,
                     cli: "betterlink settings set --showLog on", cliWhy: nil),
        ]),
        TourTopic(id: "background", title: "Always running",
                  summary: "The menu bar icon, and opening at login.",
                  symbol: "menubar.rectangle", tile: .tileNeutral, tier: .more, page: "general", steps: [
            TourStep(id: "menu-bar", revision: 1,
                     title: "betterlink lives in the menu bar",
                     body: "It has no Dock icon, and closing this window keeps it running and routing links. The menu bar icon opens the window and lists recent links. Hide the icon if you like, and open betterlink from Spotlight instead.",
                     changed: nil, symbol: "menubar.rectangle",
                     status: nil, control: .menuBarIcon, requires: nil,
                     cli: "betterlink menu-bar set --shown on", cliWhy: nil),
            TourStep(id: "open-at-login", revision: 1,
                     title: "Open betterlink at login",
                     body: "Start betterlink when you log in, so the first link after a restart opens without a pause and held keys are seen in time. macOS lists it under Login Items.",
                     changed: nil, symbol: "menubar.rectangle",
                     status: .openAtLogin, control: .openAtLogin, requires: nil,
                     cli: "betterlink login set --enabled on", cliWhy: nil),
        ]),
        TourTopic(id: "sidebar", title: "Sidebar",
                  summary: "Favorites, folders and live tabs beside your browser window. A preview.",
                  symbol: "sidebar.left", tile: .tileTeal, tier: .more, page: "tabs", steps: [
            TourStep(id: "sidebar", revision: 1,
                     title: "A sidebar for your browser",
                     body: "betterlink can sit beside a Chromium browser window, Arc style, with Favorites, folders and that window's tabs, in step with the browser both ways. It is a preview, and takes four short steps to set up. Nothing is installed until you do them.",
                     changed: nil, symbol: "sidebar.left",
                     status: nil, control: nil, requires: .sidebarBrowser,
                     cli: nil, cliWhy: nil),
            TourStep(id: "sidebar-helper", revision: 1,
                     title: "Set up the tab helper",
                     body: "Set Up writes one small file into the browser's own folder, so the browser can start betterlink's tab helper. Do it for each browser the sidebar should attach to. Uninstall removes the file.",
                     changed: nil, symbol: "sidebar.left",
                     status: .tabsHelper, control: .sidebarBrowsers, requires: .sidebarBrowser,
                     cli: "betterlink tabs setup --browser \"Google Chrome\"", cliWhy: nil),
            TourStep(id: "sidebar-extension", revision: 1,
                     title: "Add the Tabs extension",
                     body: "The extension tells betterlink about tabs the moment they change. In the browser, open chrome://extensions, turn on Developer mode, then drag the extension's folder from Finder onto the page. Do this once per browser profile, and leave Developer mode on.",
                     changed: nil, symbol: "sidebar.left",
                     status: .tabsExtension, control: .showExtension, requires: .sidebarBrowser,
                     cli: "betterlink tabs extension", cliWhy: nil),
            TourStep(id: "sidebar-accessibility", revision: 1,
                     title: "Let betterlink follow your browser windows",
                     body: "The sidebar stays against the browser window as you move and resize it. For that, macOS needs you to allow betterlink under Accessibility. betterlink uses it to follow and resize browser windows and to collapse the browser's own tab strip.",
                     changed: nil, symbol: "sidebar.left",
                     status: .accessibility, control: .allowAccessibility, requires: .sidebarBrowser,
                     cli: nil, cliWhy: "macOS grants Accessibility only in System Settings."),
            TourStep(id: "sidebar-show", revision: 2,
                     title: "Show the sidebar",
                     body: "Turn the sidebar on and every browser window of an attached browser gets its own. The shortcut (⌃⌥S unless you change it) hides or shows the sidebar of the browser window in front, and dragging an edge resizes that one. Two windows that look alike show their tabs once clicked. Once on, the Sidebar page shows its other settings.",
                     changed: "Every browser window now has its own sidebar, shown while other apps are in front, and the shortcut and a dragged edge change one window's, not all.", symbol: "sidebar.left",
                     status: .sidebar, control: .showSidebar, requires: .sidebarBrowser,
                     cli: "betterlink sidebar settings set --enabled on", cliWhy: nil),
            TourStep(id: "sidebar-library", revision: 2,
                     title: "Favorites, folders and Sidebar Profiles",
                     body: "Drag a tab onto the Favorites grid or a folder to save it; it keeps its tab, like a pinned tab in Arc, and a right-click gives a folder an emoji or a symbol. Each Sidebar Profile holds its own Favorites and folders, and the cog at the top picks which one a browser profile shows. Import from Arc or bookmarks on the Sidebar page.",
                     changed: "Folders can have an icon now: right-click one and choose an emoji or a built-in symbol, shown in place of the folder.", symbol: "sidebar.left",
                     status: nil, control: nil, requires: .sidebarBrowser,
                     cli: "betterlink sidebar icon set <folder id> --emoji 📚", cliWhy: nil),
        ]),
        TourTopic(id: "sync", title: "Sync between Macs",
                  summary: "Share rules and Sidebar Profiles through a folder your cloud drive syncs.",
                  symbol: "arrow.triangle.2.circlepath", tile: .accent, tier: .more, page: "general", steps: [
            TourStep(id: "sync-folder", revision: 1,
                     title: "Sync your setup between Macs",
                     body: "Pick a folder that Dropbox, Google Drive or iCloud Drive keeps in sync. Each Mac writes its own file there and reads the others', so edits made on two Macs both land. Permissions, and which browser profile shows which Sidebar Profile, stay on each Mac.",
                     changed: nil, symbol: "arrow.triangle.2.circlepath",
                     status: .syncFolder, control: .chooseSyncFolder, requires: nil,
                     cli: "betterlink sync set --folder ~/Dropbox/betterlink", cliWhy: nil),
        ]),
        TourTopic(id: "agents", title: "Agents and the command",
                  summary: "Let Claude Code or Codex set up betterlink with its command-line tool.",
                  symbol: "terminal.fill", tile: .tileViolet, tier: .more, page: "agents", steps: [
            TourStep(id: "command", revision: 1,
                     title: "Install the betterlink command",
                     body: "Everything this window can change, the betterlink command can change too, so a coding agent can set up your rules for you. Install links it into ~/.local/bin. Then copy the prompt on the Agents page into your agent's chat.",
                     changed: nil, symbol: "terminal.fill",
                     status: .command, control: .installCommand, requires: nil,
                     cli: nil, cliWhy: "This step installs the command itself."),
        ]),
        TourTopic(id: "dia", title: "Dia spaces",
                  summary: "Open links in the right Dia space.",
                  symbol: "square.on.square", tile: .coral, tier: .more, page: "profiles", steps: [
            TourStep(id: "dia-automation", revision: 1,
                     title: "Let betterlink switch Dia's spaces",
                     body: "Dia runs as one app and calls its profiles spaces, so betterlink switches Dia to the right space before handing it a link. The first time, macOS asks whether betterlink may control Dia. Without that, Dia links open in your fallback.",
                     changed: nil, symbol: "square.on.square",
                     status: .automationDia, control: .askDiaAutomation, requires: .dia,
                     cli: nil, cliWhy: "macOS asks in its own dialog, and only the app can be the one asking."),
        ]),
        TourTopic(id: "config", title: "config.ts",
                  summary: "Route with TypeScript when rules aren't enough.",
                  symbol: "chevron.left.forwardslash.chevron.right", tile: .tileInk, tier: .more, page: "config", steps: [
            TourStep(id: "config-ts", revision: 1,
                     title: "Route with TypeScript",
                     body: "For anything Link Rules can't express, config.ts is a small function that sees each link, the app it came from and the keys held, and returns a profile. betterlink type-checks it when you save, and keeps the last version that worked.",
                     changed: nil, symbol: "chevron.left.forwardslash.chevron.right",
                     status: .config, control: .createConfig, requires: nil,
                     cli: "betterlink config init", cliWhy: nil),
        ]),
        TourTopic(id: "updates", title: "Updates",
                  summary: "betterlink checks once a day, and asks before installing.",
                  symbol: "arrow.down.circle.fill", tile: .tileNeutral, tier: .more, page: "general", steps: [
            TourStep(id: "updates", revision: 1,
                     title: "betterlink keeps itself up to date",
                     body: "Once a day it asks GitHub whether a newer version is out, and sends nothing about you or your links. It asks before installing. After an update, What's New shows only the steps that are new since you last looked.",
                     changed: nil, symbol: "arrow.down.circle.fill",
                     status: nil, control: .automaticUpdates, requires: nil,
                     cli: "betterlink updates set --automatic on", cliWhy: nil),
            TourStep(id: "changelog", revision: 1,
                     title: "See what changed in each release",
                     body: "The Changelog page lists every release, newest first: the day it shipped and what it changed, each line linked to the pull request behind it. It is built from betterlink's release history, so it never falls behind.",
                     changed: nil, symbol: "arrow.down.circle.fill",
                     status: nil, control: nil, requires: nil,
                     cli: "betterlink changelog list --limit 3", cliWhy: nil),
        ]),
    ]
}
