// The betterlink command, for people and coding agents.
//
// Every command is a thin layer over `Betterlink agent <command> '<json>'`,
// the app's own binary: all checks and every write happen in the same Swift
// code the app routes links with, so the CLI can never disagree with the
// window. This file only describes the commands (for --help, --llms, skills
// and MCP) and passes inputs through.
//
// No network: incur's update check is off (`update: false`).

import { execFileSync } from 'node:child_process'
import { existsSync, realpathSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { Cli, Errors, z } from 'incur'

/** What to do when the command runs outside betterlink.app. The app may live
 *  anywhere, and ~/.local/bin may not exist or be on PATH. */
export const appNotFoundHint =
  'Open betterlink and use Agents › Install Command. Or link the command inside the app into a folder on your PATH, ' +
  'using wherever betterlink.app is (usually /Applications): ' +
  'mkdir -p ~/.local/bin && ln -s /Applications/betterlink.app/Contents/Helpers/betterlink ~/.local/bin/betterlink ' +
  '(then add ~/.local/bin to PATH if your shell can\'t find betterlink).'

/** The app binary: BETTERLINK_APP_BINARY (tests), else ../MacOS/Betterlink
 *  next to this executable inside betterlink.app (after following links,
 *  such as ~/.local/bin/betterlink). */
export function appBinary(): string {
  const fromEnv = process.env.BETTERLINK_APP_BINARY
  if (fromEnv) return fromEnv
  const here = realpathSync(process.execPath)
  const candidate = join(dirname(here), '..', 'MacOS', 'Betterlink')
  if (existsSync(candidate)) return candidate
  throw new Errors.IncurError({
    code: 'APP_NOT_FOUND',
    message: `Couldn't find betterlink.app next to ${here}.`,
    hint: appNotFoundHint,
  })
}

type Envelope = { version: number; ok: boolean; data?: unknown; error?: string }

/** Runs one agent command in the app binary and returns its data. */
export function core(command: string, input: Record<string, unknown> = {}): unknown {
  const clean = Object.fromEntries(Object.entries(input).filter(([, v]) => v !== undefined))
  // Outside the try, so APP_NOT_FOUND and its hint reach the caller unchanged.
  const app = appBinary()
  let out: string
  try {
    out = execFileSync(app, ['agent', command, JSON.stringify(clean)], { encoding: 'utf8' })
  } catch (e) {
    // Non-zero exit: the envelope is still on stdout.
    out = (e as { stdout?: string }).stdout ?? ''
    if (!out) throw new Errors.IncurError({ code: 'APP_FAILED', message: `betterlink didn't answer: ${String(e)}` })
  }
  let env: Envelope
  try {
    env = JSON.parse(out) as Envelope
  } catch {
    throw new Errors.IncurError({ code: 'BAD_ANSWER', message: `betterlink gave an answer that isn't JSON: ${out.slice(0, 200)}` })
  }
  if (!env.ok) throw new Errors.IncurError({ code: 'REFUSED', message: env.error ?? 'betterlink refused the change.' })
  return env.data ?? { ok: true }
}

const profileOptions = {
  profile: z.string().describe('Profile name ("Work") or folder ("Profile 1")'),
  browser: z.string().optional().describe('Browser name ("Google Chrome") or bundle id; needed when two browsers have the profile'),
}

/** An on/off switch. A z.boolean() option would drop a separate value:
 *  `--enabled false` arrived as true. */
const onOff = (what: string) => z.enum(['on', 'off']).describe(`on or off: ${what}`)
const isOn = (v: 'on' | 'off') => v === 'on'

const kind = z.enum(['domain', 'startsWith', 'contains'])
  .describe('domain: the site and its subdomains; startsWith: a link prefix; contains: text anywhere in the link')

const rules = Cli.create('rules', { description: 'Link Rules: the first rule that matches a link decides where it opens' })
  .command('list', {
    description: 'List rules in the order they are checked, each with the rules for other profiles that can take the same links',
    options: z.object({
      profile: z.string().optional().describe('Only this profile\'s rules, still numbered by their place in the full list'),
      browser: z.string().optional().describe('Browser name or bundle id, with --profile, when two browsers have the profile'),
    }),
    run: (c) => core('rules.list', c.options),
  })
  .command('profiles', {
    description: 'List the profiles that have rules, as the Link Rules page does: rule count, positions, and how many another profile\'s rule hides',
    run: () => core('rules.profiles'),
  })
  .command('add', {
    description: 'Add a rule',
    options: z.object({
      kind,
      pattern: z.string().describe('example.com, https://app.example.com/billing, or text'),
      ...profileOptions,
      position: z.number().int().positive().optional().describe('1 puts it first; default is last'),
    }),
    run: (c) => core('rules.add', c.options),
  })
  .command('update', {
    description: 'Change a rule',
    args: z.object({ id: z.string().describe('Rule id from rules list') }),
    options: z.object({
      kind: kind.optional(),
      pattern: z.string().optional(),
      profile: z.string().optional(),
      browser: z.string().optional(),
    }),
    run: (c) => core('rules.update', { id: c.args.id, ...c.options }),
  })
  .command('remove', {
    description: 'Remove a rule',
    args: z.object({ id: z.string().describe('Rule id from rules list') }),
    run: (c) => core('rules.remove', { id: c.args.id }),
  })
  .command('move', {
    description: 'Move a rule to a new position',
    args: z.object({ id: z.string().describe('Rule id from rules list') }),
    options: z.object({ to: z.number().int().positive().describe('New position, starting at 1') }),
    run: (c) => core('rules.move', { id: c.args.id, to: c.options.to }),
  })

const keyNames = z.string()
  .describe('Modifier keys, comma separated: control, option, shift, command (or ctrl, alt, cmd). Example: control,command')

const keys = Cli.create('keys', {
  description: 'Modifier keys: hold them while clicking a link to open it in a profile. Checked before config.ts and Link Rules; the keys must match exactly',
})
  .command('list', { description: 'List modifier key rules', run: () => core('keys.list') })
  .command('add', {
    description: 'Open links clicked while holding these keys in a profile',
    options: z.object({ keys: keyNames, ...profileOptions }),
    run: (c) => core('keys.add', c.options),
  })
  .command('update', {
    description: 'Change the keys or the profile of a modifier key rule',
    args: z.object({ id: z.string().describe('Id from keys list') }),
    options: z.object({
      keys: keyNames.optional(),
      profile: z.string().optional(),
      browser: z.string().optional(),
    }),
    run: (c) => core('keys.update', { id: c.args.id, ...c.options }),
  })
  .command('remove', {
    description: 'Remove a modifier key rule',
    args: z.object({ id: z.string().describe('Id from keys list') }),
    run: (c) => core('keys.remove', { id: c.args.id }),
  })

const fallback = Cli.create('fallback', { description: 'Where links that match no rule open' })
  .command('get', { description: 'Show the fallback profile', run: () => core('fallback.get') })
  .command('set', {
    description: 'Set the fallback profile',
    options: z.object(profileOptions),
    run: (c) => core('fallback.set', c.options),
  })

const profiles = Cli.create('profiles', { description: 'Browser profiles that rules can open links in' })
  .command('list', { description: 'List profiles, grouped by browser', run: () => core('profiles.list') })
  .command('add', {
    description: 'Add a profile by hand',
    options: z.object({
      browser: z.string().describe('Browser name or bundle id (see browsers list)'),
      directory: z.string().describe('Chromium folder ("Default", "Profile 1"; see chrome://version) or Firefox profile name'),
      name: z.string().describe('Name shown in betterlink'),
      color: z.string().optional().describe('Colour like #5B8DEF'),
    }),
    run: (c) => core('profiles.add', c.options),
  })
  .command('update', {
    description: 'Rename or recolour a profile',
    options: z.object({
      browser: z.string(),
      directory: z.string(),
      name: z.string().optional(),
      color: z.string().optional(),
    }),
    run: (c) => core('profiles.update', c.options),
  })
  .command('remove', {
    description: 'Remove a profile (refused while a rule or the fallback uses it)',
    options: z.object({ browser: z.string(), directory: z.string() }),
    run: (c) => core('profiles.remove', c.options),
  })
  .command('import', {
    description: "Read every installed browser's profile list (needs access to other apps' data; a terminal usually has it)",
    run: () => core('profiles.import'),
  })

const browsers = Cli.create('browsers', { description: 'Browsers betterlink supports that are installed' })
  .command('list', { description: 'List installed browsers', run: () => core('browsers.list') })

const settings = Cli.create('settings', { description: "betterlink's own settings" })
  .command('get', { description: 'Show settings', run: () => core('settings.get') })
  .command('set', {
    description: 'Show or hide the Log page',
    options: z.object({ showLog: onOff('show the Log page in the sidebar') }),
    run: (c) => core('settings.set', { showLog: isOn(c.options.showLog) }),
  })

const folder = Cli.create('folder', { description: 'The folder holding rules.json and config.ts' })
  .command('get', { description: 'Show the settings folder', run: () => core('folder.get') })
  .command('set', {
    description: 'Use another settings folder (settings are copied over; the old folder is left as is)',
    options: z.object({ path: z.string().describe('Folder to use') }),
    run: (c) => core('folder.set', { path: c.options.path }),
  })
  .command('reset', {
    description: 'Go back to the standard folder, ~/Library/Application Support/betterlink',
    run: () => core('folder.set', { standard: true }),
  })

const config = Cli.create('config', { description: 'config.ts: optional TypeScript rules that run before Link Rules' })
  .command('path', { description: "Show config.ts's path", run: () => core('config.path') })
  .command('init', { description: 'Create a starter config.ts (never overwrites)', run: () => core('config.init') })
  .command('check', {
    description: 'Type-check config.ts exactly as betterlink does and list the errors',
    run: () => core('config.check'),
  })

const defaultBrowser = Cli.create('default-browser', { description: 'Whether betterlink is the default browser' })
  .command('get', { description: 'Show whether betterlink is the default browser', run: () => core('default-browser.get') })
  .command('set', {
    description: 'Ask macOS to make betterlink the default browser (the user must confirm)',
    run: () => core('default-browser.set'),
  })

const login = Cli.create('login', { description: 'Open betterlink when you log in' })
  .command('get', { description: 'Show whether betterlink opens at login', run: () => core('login.get') })
  .command('set', {
    description: 'Turn Open at login on or off',
    options: z.object({ enabled: onOff('open betterlink when you log in') }),
    run: (c) => core('login.set', { enabled: isOn(c.options.enabled) }),
  })

const menuBar = Cli.create('menu-bar', { description: "betterlink's menu bar icon (this Mac only)" })
  .command('get', { description: 'Show whether the menu bar icon is shown', run: () => core('menu-bar.get') })
  .command('set', {
    description: 'Show or hide the menu bar icon (when hidden, open betterlink from Spotlight to see its window)',
    options: z.object({ shown: onOff('show betterlink in the menu bar') }),
    run: (c) => core('menu-bar.set', { shown: isOn(c.options.shown) }),
  })

const toast = Cli.create('toast', {
  description: 'The small toast saying which profile a rule chose (this Mac only; on by default)',
})
  .command('get', { description: 'Show whether the toast is on, and where it appears', run: () => core('toast.get') })
  .command('set', {
    description: 'Turn the toast on or off, or move it to the top or bottom of the screen',
    options: z.object({
      shown: onOff('show a toast when a rule picks the profile').optional(),
      position: z.enum(['top', 'bottom']).optional().describe('top or bottom middle of the screen'),
    }),
    run: (c) => core('toast.set', {
      shown: c.options.shown === undefined ? undefined : isOn(c.options.shown),
      position: c.options.position,
    }),
  })

const updates = Cli.create('updates', { description: 'Automatic updates (this Mac only)' })
  .command('get', {
    description: 'Show the version, whether betterlink checks for updates by itself, and whether it installs them',
    run: () => core('updates.get'),
  })
  .command('set', {
    description: 'Turn the hourly update check, or installing updates without asking, on or off',
    options: z.object({
      automatic: onOff('check GitHub for a newer betterlink once an hour').optional(),
      install: onOff('download updates in the background and install them while the Mac is idle, instead of asking first').optional(),
    }),
    run: (c) => core('updates.set', {
      automatic: c.options.automatic === undefined ? undefined : isOn(c.options.automatic),
      install: c.options.install === undefined ? undefined : isOn(c.options.install),
    }),
  })

// The sidebar's saved things (sidebar.json): Sidebar Profiles, Favorites,
// folders, saved links, which browser profile shows which, imports. Ids come
// from `sidebar list`; the first 4+ characters of an id are enough.
const sidebarProfileOption = {
  profile: z.string().optional().describe('Sidebar Profile name or id; needed when there is more than one'),
}
const whereOptions = {
  to: z.string().optional().describe('"favorites", "top", or a folder id'),
  position: z.number().int().positive().optional().describe('1 puts it first; default is last'),
}
// One id, or several with commas between them: what the sidebar does for
// several picked rows (Command-click, Shift-click).
const idList = (text: string) => text.split(',').map((t) => t.trim()).filter(Boolean)
const oneOrSeveral = (text: string) => {
  const ids = idList(text)
  return ids.length > 1 ? { ids } : { id: ids[0] ?? text }
}
const tabList = (text: string) => {
  const ids = idList(text).map(Number)
  if (ids.length === 0 || ids.some((n) => !Number.isInteger(n))) {
    throw new Errors.IncurError({ code: 'REFUSED', message: 'Give tab ids from tabs list, comma separated, such as 12,34.' })
  }
  return ids
}
const browserProfileOptions = {
  browser: z.string().describe('Browser name ("Google Chrome") or bundle id'),
  browserProfile: z.string().describe('The browser profile\'s folder: "Default", "Profile 1" (profiles list)'),
}

const sidebarProfiles = Cli.create('profiles', {
  description: 'Sidebar Profiles: each holds its own Favorites and folders, and shows for the browser profiles assigned to it',
})
  .command('add', {
    description: 'Make a Sidebar Profile',
    options: z.object({ name: z.string() }),
    run: (c) => core('sidebar.profiles.add', c.options),
  })
  .command('rename', {
    description: 'Rename a Sidebar Profile',
    options: z.object({ profile: z.string().describe('Its current name or id'), name: z.string().describe('The new name') }),
    run: (c) => core('sidebar.profiles.rename', c.options),
  })
  .command('remove', {
    description: 'Delete a Sidebar Profile and everything saved in it (the last one stays)',
    options: z.object({ profile: z.string().describe('Name or id') }),
    run: (c) => core('sidebar.profiles.remove', c.options),
  })
  .command('assign', {
    description: 'Show this Sidebar Profile for a browser profile (this Mac only; never synced)',
    options: z.object({ profile: z.string().describe('Sidebar Profile name or id'), ...browserProfileOptions }),
    run: (c) => core('sidebar.profiles.assign', c.options),
  })
  .command('unassign', {
    description: 'Let a browser profile show the default Sidebar Profile again',
    options: z.object(browserProfileOptions),
    run: (c) => core('sidebar.profiles.unassign', c.options),
  })

const sidebarSettings = Cli.create('settings', { description: 'The sidebar on this Mac: on or off, shown or hidden, side, width, browsers' })
  .command('get', { description: 'Show the sidebar settings. shown and width are what a window gets when nothing was chosen for it; a window hidden with the shortcut, or with its edge dragged, has its own', run: () => core('sidebar.settings.get') })
  .command('set', {
    description: 'Change the sidebar settings; the running app applies them at once',
    options: z.object({
      enabled: onOff('the sidebar').optional(),
      shown: onOff('show it in every window, or hide it and give the windows their space back (the shortcut does one window)').optional(),
      side: z.enum(['left', 'right']).optional(),
      width: z.number().min(200).max(440).optional().describe("Points, 200 to 440, for every window's sidebar (dragging an edge sets one window's)"),
      takeOverTabs: onOff("switch the browser's own tab strip to its collapsed vertical tabs").optional(),
      browsers: z.string().optional().describe('Browsers it attaches to, comma separated names or bundle ids'),
      shortcut: z.string().optional().describe('The show/hide shortcut, Control with a key: "ctrl+opt+s" or "⌃⌥S"'),
      findShortcut: z.string().optional().describe('The Find a Tab shortcut, Control with a key: "ctrl+opt+f" or "⌃⌥F"'),
    }),
    run: (c) => {
      const o = c.options
      return core('sidebar.settings.set', {
        enabled: o.enabled && isOn(o.enabled),
        shown: o.shown && isOn(o.shown),
        side: o.side,
        width: o.width,
        takeOverTabs: o.takeOverTabs && isOn(o.takeOverTabs),
        browsers: o.browsers?.split(',').map((b) => b.trim()).filter(Boolean),
        shortcut: o.shortcut,
        findShortcut: o.findShortcut,
      })
    },
  })

const sidebarIcon = Cli.create('icon', {
  description: "A folder's icon, shown in place of the folder glyph: an emoji, or a built-in symbol (synced with the folder)",
})
  .command('set', {
    description: 'Give a folder an emoji or a built-in symbol (give one of --emoji and --symbol)',
    args: z.object({ id: z.string().describe('Folder id from sidebar list') }),
    options: z.object({
      emoji: z.string().optional().describe('One emoji, such as 📚'),
      symbol: z.string().optional().describe('A built-in symbol\'s name, such as star.fill or folder.badge.person.crop (the SF Symbols app lists them)'),
      ...sidebarProfileOption,
    }),
    run: (c) => core('sidebar.folders.icon', { id: c.args.id, ...c.options }),
  })
  .command('clear', {
    description: "Take a folder's icon away, so it shows the folder glyph again",
    args: z.object({ id: z.string().describe('Folder id from sidebar list') }),
    options: z.object(sidebarProfileOption),
    run: (c) => core('sidebar.folders.icon', { id: c.args.id, profile: c.options.profile, clear: true }),
  })

const sidebar = Cli.create('sidebar', {
  description: "The sidebar's saved things: Sidebar Profiles, Favorites, folders and saved links, imports, and its settings",
})
  .command('list', { description: 'Every Sidebar Profile with its Favorites and folders (and their icons), with ids', run: () => core('sidebar.list') })
  .command(sidebarProfiles)
  .command('add-folder', {
    description: 'Make a folder, empty or holding things you already saved (--with, the sidebar\'s New Folder with Selection)',
    options: z.object({
      name: z.string(),
      ...sidebarProfileOption,
      to: z.string().optional().describe('"top" or a folder id to put it in'),
      position: whereOptions.position,
      with: z.string().optional().describe('Ids to move into the new folder, comma separated; it then stands where the first of them stood unless --to or --position says otherwise'),
    }),
    run: (c) => {
      const { with: holding, ...rest } = c.options
      return core('sidebar.folders.add', holding === undefined ? rest : { ...rest, with: idList(holding) })
    },
  })
  .command('add-link', {
    description: 'Save a link in a folder, at the top level, or as a Favorite',
    options: z.object({ url: z.string(), title: z.string().optional(), ...sidebarProfileOption, ...whereOptions }),
    run: (c) => core('sidebar.links.add', c.options),
  })
  .command('update', {
    description: 'Rename a Favorite, folder or saved link, or point a link at another page',
    args: z.object({ id: z.string().describe('Id from sidebar list') }),
    options: z.object({ name: z.string().optional().describe('New name or title'), url: z.string().optional(), ...sidebarProfileOption }),
    run: (c) => core('sidebar.items.update', { id: c.args.id, ...c.options }),
  })
  .command('move', {
    description: 'Move or reorder a Favorite, folder or saved link (into Favorites, a folder, or the top level), or several together with --to',
    args: z.object({ id: z.string().describe('Id from sidebar list, or several with commas between them') }),
    options: z.object({ ...sidebarProfileOption, ...whereOptions }),
    run: (c) => core('sidebar.items.move', { ...oneOrSeveral(c.args.id), ...c.options }),
  })
  .command('remove', {
    description: 'Delete a Favorite, folder or saved link, or several at once',
    args: z.object({ id: z.string().describe('Id from sidebar list, or several with commas between them') }),
    options: z.object({ ...sidebarProfileOption, withContents: z.boolean().optional().describe('Needed to delete a folder that has things in it') }),
    run: (c) => core('sidebar.items.remove', { ...oneOrSeveral(c.args.id), ...c.options }),
  })
  .command('expand', {
    description: 'Open or close a folder, or every folder with --all (as Option-click on a folder does)',
    args: z.object({ id: z.string().optional().describe('Folder id from sidebar list; leave out with --all') }),
    options: z.object({
      ...sidebarProfileOption,
      open: onOff('the folder'),
      all: z.boolean().optional().describe('Every folder in the Sidebar Profile, at every depth'),
    }),
    run: (c) => core('sidebar.items.expand', { id: c.args.id, all: c.options.all, profile: c.options.profile, expanded: isOn(c.options.open) }),
  })
  .command(sidebarIcon)
  .command('import', {
    description: 'Import bookmarks (into one closed folder) or Arc\'s sidebar (each Space becomes a Sidebar Profile)',
    options: z.object({
      from: z.enum(['browser', 'file', 'arc']).describe('browser: a Chromium profile\'s bookmarks; file: bookmarks.html, a Bookmarks file or StorableSidebar.json; arc: Arc on this Mac'),
      path: z.string().optional().describe('With from file'),
      browser: z.string().optional().describe('With from browser'),
      browserProfile: z.string().optional().describe('With from browser: "Default", "Profile 1"'),
      ...sidebarProfileOption,
    }),
    run: (c) => core('sidebar.import', c.options),
  })
  .command(sidebarSettings)

// Live tabs, through the browser's Tabs extension. Tab and window ids come from `tabs list`.
const tabId = z.object({
  tab: z.number().int().describe('Tab id from tabs list'),
  browser: z.string().optional().describe('Only when two browsers have a tab with this id'),
})
// One tab (--tab) or several (--tabs 12,34), for what the sidebar does to
// several picked tabs.
const tabIds = z.object({
  tab: z.number().int().optional().describe('Tab id from tabs list'),
  tabs: z.string().optional().describe('Several tab ids, comma separated'),
  browser: z.string().optional().describe('Only when two browsers have a tab with one of these ids'),
})
const severalTabs = (o: { tab?: number; tabs?: string; browser?: string }) => ({
  tab: o.tab,
  tabs: o.tabs === undefined ? undefined : tabList(o.tabs),
  browser: o.browser,
})
const tabs = Cli.create('tabs', { description: 'Open tabs in browsers with the betterlink Tabs extension: list, open, close, move and more' })
  .command('list', { description: 'Every connected browser window and its tabs', run: () => core('tabs.list') })
  .command('extension', {
    description: 'Where the Tabs extension is on this Mac, for Load unpacked in a browser (it updates with betterlink)',
    run: () => core('tabs.extension'),
  })
  .command('helpers', {
    description: 'Each installed browser the sidebar can attach to, whether its tab helper is set up, and which of its profiles have the Tabs extension connected',
    run: () => core('tabs.helper.list'),
  })
  .command('setup', {
    description:
      "Set up a browser's tab helper: writes one file into the browser's NativeMessagingHosts folder so it can start betterlink's helper (the Sidebar page's Set Up)",
    options: z.object({
      browser: z.string().describe('Browser name ("Google Chrome") or bundle id, from tabs helpers'),
      remove: onOff('remove the file instead (the Sidebar page\'s Uninstall)').optional(),
    }),
    run: (c) => core('tabs.helper.set', { browser: c.options.browser, remove: c.options.remove && isOn(c.options.remove) }),
  })
  .command('open', {
    description: 'Open a page in a new tab',
    args: z.object({ url: z.string() }),
    options: z.object({
      window: z.number().int().optional().describe('Window id; default is the focused window'),
      browser: z.string().optional().describe('Only when two browsers have a window with this id'),
    }),
    run: (c) => core('tabs.open', { url: c.args.url, window: c.options.window, browser: c.options.browser }),
  })
  .command('close', {
    description: 'Close tabs',
    args: z.object({ tabs: z.string().describe('Tab ids, comma separated') }),
    options: z.object({ browser: z.string().optional().describe('Only when two browsers have a tab with one of these ids') }),
    run: (c) => core('tabs.close', { tabs: tabList(c.args.tabs), browser: c.options.browser }),
  })
  .command('save', {
    description:
      "Save open tabs' pages in the sidebar: as Favorites, in a folder, or in a new folder (the sidebar's Add to Favorites, Save to Folder and New Folder with Selection). The tabs stay open",
    args: z.object({ tabs: z.string().describe('Tab ids, comma separated') }),
    options: z.object({
      ...whereOptions,
      folder: z.string().optional().describe('Name for a new folder to save them in (made at --to, which is then "top" or a folder id)'),
      ...sidebarProfileOption,
      browser: z.string().optional().describe('Only when two browsers have a tab with one of these ids'),
    }),
    run: (c) => core('tabs.save', { tabs: tabList(c.args.tabs), ...c.options }),
  })
  .command('find', {
    description: 'Find open tabs in every connected browser and profile by words from their title or address (the Find Tab panel); then tabs activate',
    args: z.object({ query: z.string().describe('Words from the title or address, in any order') }),
    run: (c) => core('tabs.find', { query: c.args.query }),
  })
  .command('activate', { description: 'Switch to a tab', options: tabId, run: (c) => core('tabs.activate', c.options) })
  .command('move', {
    description: 'Move a tab within its window, or into another window',
    options: tabId.extend({ position: z.number().int().positive().describe('1 is first'), window: z.number().int().optional() }),
    run: (c) => core('tabs.move', c.options),
  })
  .command('mute', { description: 'Mute a tab, or several with --tabs', options: tabIds, run: (c) => core('tabs.mute', { ...severalTabs(c.options), muted: true }) })
  .command('unmute', { description: 'Unmute a tab, or several with --tabs', options: tabIds, run: (c) => core('tabs.mute', { ...severalTabs(c.options), muted: false }) })
  .command('duplicate', { description: 'Open the same page in a second tab', options: tabId, run: (c) => core('tabs.duplicate', c.options) })
  .command('reload', { description: 'Reload a tab, or several with --tabs', options: tabIds, run: (c) => core('tabs.reload', severalTabs(c.options)) })
  .command('navigate', {
    description: 'Send a tab to another page',
    options: tabId.extend({ url: z.string() }),
    run: (c) => core('tabs.navigate', c.options),
  })
  .command('new-window', { description: 'Move a tab to a new window', options: tabId, run: (c) => core('tabs.new-window', c.options) })
  .command('send', {
    description: 'Send a tab to another browser profile or browser: it opens there, then closes here (the sidebar\'s Send to Another Profile)',
    options: z.object({
      tab: z.number().int().describe('Tab id from tabs list'),
      browser: z.string().optional().describe('Only when two browsers have a tab with this id'),
      to: z.string().describe('The profile as tabs list names it ("Work (Google Chrome)"), or a profile or browser name'),
    }),
    run: (c) => core('tabs.send', c.options),
  })
  .command('close-others', {
    description: "Close the window's other tabs (saved links' tabs stay open)",
    options: tabId,
    run: (c) => core('tabs.close-others', c.options),
  })
  .command('close-below', {
    description: 'Close the tabs below this one (saved links\' tabs stay open)',
    options: tabId,
    run: (c) => core('tabs.close-below', c.options),
  })

const sync = Cli.create('sync', {
  description: 'Sync between Macs through a folder your cloud drive keeps in sync (this Mac only: each Mac picks its own folder)',
})
  .command('get', { description: 'Show the sync folder, what this Mac syncs, and the other Macs with when each last synced', run: () => core('sync.get') })
  .command('set', {
    description: 'Choose the sync folder, turn Sync off, or choose what syncs; a running betterlink starts at once',
    options: z.object({
      folder: z.string().optional().describe('A folder that exists, inside Dropbox, Google Drive or iCloud Drive'),
      off: onOff('turn Sync off on this Mac (its file stays in the folder)').optional(),
      global: onOff('sync Link Rules, modifier keys, the fallback, Show log and config.ts').optional(),
      profile: z.string().optional().describe('A Sidebar Profile, by name or id (sidebar list); give parts with it'),
      parts: z.string().optional().describe('What of that Sidebar Profile syncs, comma separated: favorites, folders, name. "none" keeps it on this Mac'),
    }),
    run: (c) => {
      const o = c.options
      const parts = o.parts === undefined ? undefined : o.parts === 'none' ? [] : o.parts.split(',').map((p) => p.trim()).filter(Boolean)
      if (parts !== undefined && o.parts !== 'none' && parts.length === 0) {
        throw new Errors.IncurError({ code: 'REFUSED', message: 'Give parts as favorites, folders, name (comma separated), or none.' })
      }
      return core('sync.set', {
        folder: o.folder,
        off: o.off && isOn(o.off),
        global: o.global && isOn(o.global),
        profile: o.profile,
        parts,
      })
    },
  })
  .command('add', {
    description: 'Add a Sidebar Profile another Mac shares (sync get lists them under offered); the next sync copies it in',
    options: z.object({ profile: z.string().describe('The shared Sidebar Profile, by name or id (sync get, offered)') }),
    run: (c) => core('sync.add', { profile: c.options.profile }),
  })
  .command('merge', {
    description: "Make a shared Sidebar Profile and this Mac's one with the same name one profile on every Mac, keeping everything in both",
    options: z.object({ profile: z.string().describe('The name both have, such as Primary, or the shared one\'s id (sync get, offered)') }),
    run: (c) => core('sync.merge', { profile: c.options.profile }),
  })
  .command('paused', {
    description: 'Show whether Sync is paused because this Mac would delete many synced items at once, and which',
    run: () => core('sync.paused'),
  })
  .command('resolve', {
    description: 'Answer a pause: delete those items on every Mac once, or keep them and take them back on this Mac',
    options: z.object({
      choice: z.enum(['delete', 'keep']).describe('delete: delete them everywhere; keep: bring the shared ones back here'),
    }),
    run: (c) => core('sync.resolve', { choice: c.options.choice }),
  })
  .command('history', {
    description: 'What sync deleted on this Mac or replaced with another Mac\'s edit, newest first (the last 50, up to 30 days)',
    run: () => core('sync.history'),
  })
  .command('restore', {
    description: 'Put back what a sync history entry deleted or replaced, as a new edit on this Mac, so it wins everywhere',
    args: z.object({ id: z.string().describe('An entry id from sync history, or its start') }),
    run: (c) => core('sync.restore', { id: c.args.id }),
  })

// The tour: the first-run flow and What's New (docs/tour.md). Step and topic
// ids come from `tour status`.
const tourTarget = {
  step: z.string().optional().describe('One step, by id (tour status)'),
  topic: z.string().optional().describe("One topic's steps, by id (tour status)"),
}
// A bare word after the command would be dropped and the command would act on
// the whole tour (`tour reset link-rules` forgetting everything), so it is
// refused.
const tourStray = z.object({ what: z.string().optional().describe('Not used: name a step or topic with --step or --topic') })
function refuseStray(what: string | undefined, flags: string) {
  if (what !== undefined) {
    throw new Errors.IncurError({ code: 'REFUSED', message: `"${what}" isn't an option. Say which with ${flags} (ids: tour status).` })
  }
}
const tour = Cli.create('tour', {
  description: "betterlink's tour: the first-run flow and What's New. See what has been seen, show it, or put it back (this Mac only)",
})
  .command('status', {
    description: 'Every topic and step, which were seen, what is new, and the command that does what each step does',
    run: () => core('tour.status'),
  })
  .command('show', {
    description: "Open betterlink's window on the whole tour, or on one topic",
    args: tourStray,
    options: z.object({ topic: z.string().optional().describe('Only this topic, by id (tour status)') }),
    run: (c) => {
      refuseStray(c.args.what, '--topic')
      return core('tour.show', { topic: c.options.topic })
    },
  })
  .command('new', {
    description: "Open betterlink's window on What's New: only the steps added or changed since the tour was last seen",
    run: () => core('tour.show', { only: 'new' }),
  })
  .command('done', {
    description: 'Mark the tour seen without showing it: all of it, one topic or one step',
    args: tourStray,
    options: z.object(tourTarget),
    run: (c) => {
      refuseStray(c.args.what, '--step or --topic')
      return core('tour.done', c.options)
    },
  })
  .command('reset', {
    description: 'Forget what was seen, so it shows again: all of it (the first run comes back), one topic or one step',
    args: tourStray,
    options: z.object(tourTarget),
    run: (c) => {
      refuseStray(c.args.what, '--step or --topic')
      return core('tour.reset', c.options)
    },
  })

// The changelog this copy of betterlink was built with (the Changelog page
// shows the same). Read-only: it comes from git history at build time.
const changelog = Cli.create('changelog', {
  description: 'What changed in each release of betterlink, newest first, as built into this copy',
})
  .command('list', {
    description: 'Releases with their date and changes, newest first',
    options: z.object({
      since: z.string().optional().describe('Only releases newer than this version, e.g. 0.3.20'),
      limit: z.number().int().positive().optional().describe('At most this many releases'),
    }),
    run: (c) => core('changelog.list', c.options),
  })

export const cli = Cli.create('betterlink', {
  description:
    'Route every link to the right browser and profile. Change everything the betterlink window can: ' +
    'Link Rules, modifier keys, the fallback, profiles, config.ts and settings; the sidebar\'s Sidebar Profiles, Favorites, folders and their icons, saved links, imports and settings; ' +
    "and open tabs in browsers with the Tabs extension; Sync between Macs; the tour (the first-run flow and What's New); and read the changelog. " +
    '(The app keeps its log in memory only, so it is not here.)',
  // Set at build time from Info.plist (the Makefile's cli target).
  version: process.env.BETTERLINK_VERSION ?? 'dev',
  update: false,
})
  .command('status', { description: 'Settings folder, rule and profile counts, fallback, installed browsers', run: () => core('status') })
  .command('test', {
    description: 'Show where a link would open, and why, without opening it',
    args: z.object({ link: z.string().describe('The link to test') }),
    options: z.object({ keys: keyNames.optional().describe('Pretend these modifier keys are held, e.g. control,command') }),
    run: (c) => core('test', { link: c.args.link, keys: c.options.keys }),
  })
  .command(rules)
  .command(keys)
  .command(fallback)
  .command(profiles)
  .command(browsers)
  .command(settings)
  .command(folder)
  .command(config)
  .command(defaultBrowser)
  .command(login)
  .command(menuBar)
  .command(toast)
  .command(updates)
  .command(sidebar)
  .command(tabs)
  .command(sync)
  .command(tour)
  .command(changelog)

if (import.meta.main) cli.serve()
