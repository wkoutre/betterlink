# betterlink

A native macOS link router. Set it as your default browser, and it opens each link in the right browser and profile:
- Modifier keys: hold a combination such as ⌃⌘ while you click a link to open it in a chosen profile.
- Link Rules, made in a Dia-style editor, decide where a link opens.
- An optional `config.ts` in TypeScript runs before those rules.
- Everything else opens in your fallback profile.

Derived from [Finch](https://github.com/expelledboy/finch) (MIT). It fixes three things Finch gets wrong:

| Finch | betterlink |
|---|---|
| Reads the host with string searches. `https://evil.com\@example.com/` matched an `example.com` rule, but the browser loads evil.com. | Parses links the way browsers do (WHATWG). It opens the link it rebuilt from that parse, so the browser loads the host the rules saw. A host it can't read with certainty only ever opens in the fallback profile. |
| Brave ignores the chosen profile when it is already running. | Passes the profile and the link together on a fresh Brave command line. The link comes after `--`. |
| A missing browser hands the link back to the system, which is Finch itself. A broken config drops links silently. | Never hands a link back to the system. A broken `config.ts` keeps the last version that worked and shows the error. |

## Install

Requires macOS 15 or later on Apple silicon.

With Homebrew (it asks you to trust a tap before it installs from it):

```sh
brew trust wkoutre/tap
brew install --cask wkoutre/tap/betterlink
```

Or download `betterlink-macos.zip` from the [latest release](https://github.com/wkoutre/betterlink/releases/latest), unzip it and move `betterlink.app` to `/Applications`. Releases are signed with a Developer ID and notarized by Apple.

Or build it yourself (needs Xcode 16 or later):

```sh
make install          # builds dist/betterlink.app and copies it to /Applications
```

To bring in the profiles of the browsers you already have, run this once:

```sh
/Applications/betterlink.app/Contents/MacOS/Betterlink --import-profiles
```

The first time its window opens, betterlink shows a short tour: making it the default browser, your profiles, the fallback and a first Link Rule, then the optional parts (modifier keys, the sidebar, Sync, the command). Every step can be skipped, and **About › Tour** shows it again. After an update, anything new is offered as one line at the top of the window; it never opens by itself. See [docs/tour.md](docs/tour.md).

The same settings are under **Permissions** in the window:
- **Default browser** (required): click **Make Default Browser**.
- **Browser data** (optional): lets betterlink read each browser's profile list by itself. macOS calls this Full Disk Access; **Open Privacy Settings** goes straight to it. The page shows, per browser, whether its profiles are readable and, if not, why. Chrome and Brave usually need no grant at all; if a browser shows **Blocked** with Full Disk Access on, something else on the Mac refuses the read (often a work Mac's security software), so add its profiles by hand.
- **Open at login** (optional).

### Updates

betterlink updates itself with [Sparkle](https://sparkle-project.org). Once an hour it fetches `appcast.xml` from the latest GitHub release, a plain request that carries nothing about you or your links. When a newer version is out it downloads it in the background, checks it against betterlink's update key, and installs it the next time you leave the Mac alone for two minutes (or when betterlink quits), which restarts betterlink in about a second. The menu bar menu shows **Restart to Update** while one waits. **General › Updates** turns the hourly check or the automatic install off (then it asks first) and has **Check Now**; `betterlink updates set --automatic off` and `--install off` do the same. Only release builds check; a build from source (`make install`) never does.

betterlink runs in the background with no Dock icon. Closing its window (⌘W or the red button) keeps it running. Its menu bar icon opens the window and lists recent links; **General › Menu bar** hides the icon. With the icon hidden, open betterlink from Spotlight or Finder to get the window back.

Without browser data access, add profiles under **Profiles › Edit Profiles…**, or copy them in once from Terminal, which macOS lets read other apps' data: `/Applications/betterlink.app/Contents/MacOS/Betterlink --import-profiles`. A Chromium profile's folder is shown at `chrome://version`, at the end of Profile Path.

## Browsers

Rules and the fallback each name a browser and, where it has them, a profile.

| Family | Browsers | How a profile is chosen | Tested |
|---|---|---|---|
| Chromium | Brave, Chrome (also Beta, Canary), Chromium, Edge, Comet, Vivaldi, Helium, Opera, Opera GX, Ecosia, Wavebox, Yandex, Brave Nightly | `--profile-directory=<folder> -- <link>` on a fresh process, which a running browser hands to itself | Brave, by hand. The rest are expected to work. |
| Dia | Dia | Dia allows one copy of itself and calls its profiles spaces, so betterlink switches Dia's front window to the space with the profile's name (AppleScript `focus profile`), then hands Dia the link. macOS asks once to let betterlink control Dia. With no space of that name, or without that permission, the link opens in your fallback profile instead, so it never lands in another Dia profile, and the Log says why. Only a link already headed for a fallback that is itself a Dia space still opens in Dia's current space. | By hand (Dia 1.58). |
| Firefox | Firefox, Firefox Developer Edition, Zen | `-P <name> <link>` | Expected to work, not yet tested. |
| No profiles | Safari, Arc | the link is handed to the browser the ordinary way | Expected to work. |

betterlink finds a browser's profiles in its own files: `Local State` for Chromium and `profiles.ini` for Firefox. For the Tabs sidebar's profile color it also reads a Chromium profile's `Preferences` (its theme color) and the frame color in `Local State`. Bundle ids and data folders come from [Finicky](https://github.com/johnste/finicky)'s browser list (MIT). Profiles can also be added by hand under **Edit Profiles…**.

## Link Rules

Each rule reads "Open … in a profile". Rules are checked top to bottom, across every profile, and the first one that matches decides.

The Link Rules page lists the profiles that have rules. Click one to see and edit only its rules; each keeps its number in the full order, and **All Rules in Order** shows the whole list. Grouping hides the order between profiles, so a profile's page says where it still matters: a rule for another profile above that takes the links a rule is written for ("domains matching example.com" in Personal above "domains matching app.example.com" in Work) is marked hidden, with a button to move it above, and an exception that only works while it stays above ("URLs starting with https://github.com/acme" in Work above "domains matching github.com" in Personal) says so on both rules. Editing one profile's rules leaves every other profile's rules in their places; new rules go last.

- **domains matching** `example.com` matches example.com and every subdomain. It never matches `evil-example.com` or `example.com.evil.com`.
- **URLs starting with** `https://app.example.com/billing` needs exactly that host, then that path, ending at a `/`, `?` or `#` (so it doesn't match `/billingx`); a prefix that reaches into the query (`?tab=`) is matched as plain text. Leave the scheme out to match both http and https.
- **URLs containing** `text` matches the text anywhere in the link, so a link to any site can match it.

Rules and profiles are stored in `rules.json` in betterlink's settings folder, readable only by you.

## Modifier keys

Hold keys while you click a link to choose its profile for that one click, like Finicky's modifier rules. Set them under **Link Rules › Modifier keys › Edit Keys…**: each row reads "Hold ⌃⌘ to open links in Work".

- They are checked first, before config.ts and the Link Rules, because holding the keys is a choice made for that click.
- The keys must match exactly. ⌃⌘ doesn't match ⌃⌥⌘ or a plain ⌘-click (which is how Terminal opens links), so each combination can have its own profile. Caps Lock and fn are ignored.
- They work for any link betterlink would open, including a local file and a link whose host it can't read with certainty: the keys don't depend on the host, so a lookalike host can't fool them. Links betterlink refuses stay refused.
- betterlink reads the keys as the link arrives, so keep holding them until the browser comes forward. If betterlink isn't running yet, it may start too late to see them; turn on **Open at login** to avoid that.
- Some apps treat a modified click as their own shortcut and never send the link. Pick a combination the app ignores.

Test a combination in the link tester on the Link Rules page (the **Holding** keys), or with `betterlink test <link> --keys control,command`.

## Settings folder

By default, betterlink keeps `rules.json` and `config.ts` in `~/Library/Application Support/betterlink`, the standard place for a Mac app's files. Under **Settings folder** you can pick another one, for example a folder you sync or back up; betterlink copies your settings there and leaves the old folder untouched. For development and tests, the `BETTERLINK_HOME` environment variable overrides the folder.

A synced settings folder shares everything in `rules.json` across your Macs: the Link Rules, the modifier keys, the profiles, the fallback profile and the Log switch. If the fallback names a browser a Mac doesn't have, that Mac opens unmatched links in the Default profile of the first Chromium browser it has installed, trying them in this order: Brave, Brave Nightly, Chrome, Chrome Beta, Chrome Canary, Chromium, Edge, Dia, Comet, then the rest of the Chromium row in [Browsers](#browsers); or in Safari if it has none. Run 0.2 or later on every Mac that shares the folder: an older betterlink drops the fallback and the Log switch when it saves. Likewise, a betterlink without modifier keys drops them when it saves.

## config.ts (optional)

`config.ts` in the settings folder runs before the Link Rules. Return a profile name to choose it, or `undefined` to let the rules decide. `link.modifiers` lists the modifier keys held for the click (`["control", "command"]`) when no modifier key rule claimed it:

```ts
export default function route(link: Link): Target | undefined {
  if (link.opener === "com.tinyspeck.slackmacgap" && link.host.endsWith("example.com")) {
    return { browser: "Google Chrome", profile: "Work" };
  }
  return undefined;
}
```

Return a profile name on its own (`"Work"`) when only one profile has that name, or `{ browser, profile }`. A name more than one profile uses is left out of `ProfileName`, so returning it bare fails the type check. That means adding a same-named profile to another browser (or installing Firefox Developer Edition next to Firefox, which share profiles) stops a config.ts that returns that name until you add the browser. Two profiles with the same name in one browser can't be told apart at all: rename one in the browser. Without browser data access you can rename it under **Profiles › Edit Profiles…** instead; with access, betterlink takes names from the browser, so a rename there wouldn't stick.

How it's checked and run:
- betterlink type-checks it with its own copy of the TypeScript compiler, 6.0.3, the last release written in JavaScript. Nothing needs to be installed.
- It checks the file each time you save it, not on every link.
- It writes `betterlink.d.ts` and `tsconfig.json` next to the file, so your editor shows the same types, including your real profile names.
- The script runs in JavaScriptCore with no file, network or process access.
- Each call has a 0.25 s limit. `console.log` writes to the in-app log.
- If the file throws, runs too long, or returns an unknown profile, the link goes to the fallback profile.

## Link toast

When held keys, config.ts or a Link Rule picks the profile, a small badge fades in at the top middle of the screen the pointer is on, for example "● Work  Rule 2", and fades out after about two seconds. Links that open in the fallback show none. It never takes focus or clicks. Turn it off, or move it to the bottom, under **General › Link toast** (this Mac only), or with `betterlink toast set --shown off` / `--position bottom`. With Reduce Motion on, it fades without sliding.

## Log

Turn on **General › Show the log in the sidebar** to see every link, where it went, and why. The log is kept in memory only:
- it is gone when betterlink quits;
- links are never written to disk or the system log.

## Sidebar

A sidebar beside every Chromium browser window, Arc-style, with every open tab synced both ways the instant anything changes and no polling: a small browser extension pushes each tab event to betterlink over native messaging, and betterlink's open, switch and close commands go back the same way. Off until you open the Sidebar page, show the sidebar and connect a browser. The Sidebar page shows only **Show the sidebar** until that is on. The extension comes with the app: Sidebar page › Browsers › **Show in Finder**, then drag that folder onto chrome://extensions with Developer mode on, once per browser profile. After that it updates with betterlink. See [docs/tabs.md](docs/tabs.md).

## Accepted risks

1. **Another app can reroute your links.** Any program running as you can edit `config.ts` or `rules.json`. betterlink refuses either file if someone else owns it, or if other users can write to it or to its folder. It does not defend against malware already running as you.
   It doesn't lend that program its own permissions, though. The `betterlink` command runs with the permissions of whatever started it (your terminal, a script, an agent), and it refuses to start the way an app is started (`open -a betterlink.app --args agent …`), where it would run with betterlink's own Full Disk Access. Switching settings folders links a symlinked `rules.json` or `config.ts` into the new folder instead of copying what it points to.
2. **betterlink sees every link you open.** It keeps them in memory only and sends nothing anywhere. Its only network request is the update check (see Updates), which carries no link or setting.
3. **A build from source isn't notarized.** Releases are signed and notarized. `make build` and `make install` sign a local build with a Developer ID Application certificate when your keychain has one, and macOS then keeps its permissions (such as Full Disk Access and Accessibility) across rebuilds. If that certificate is betterlink's own (team JJDAHS4TUV), macOS can't tell the build from the release, so the two share those permissions. Without a certificate the build is ad-hoc signed, and macOS forgets its permissions each time you rebuild.
4. **Lookalike domains open in the fallback profile.** For example `exаmple.com` with a Cyrillic а. betterlink doesn't try to detect them.

## Command line and coding agents

betterlink includes a `betterlink` command for people and coding agents (Claude Code, Codex and others). It can change everything the window can:
- Link Rules;
- modifier keys;
- the fallback;
- profiles;
- config.ts;
- the settings folder;
- the Log switch;
- Open at login;
- the menu bar icon;
- automatic update checks;
- the link toast;
- default browser;
- the sidebar: Sidebar Profiles (and which browser profile shows each), Favorites, folders and saved links (add, rename, repoint, move, delete, open or close, and a folder's icon: an emoji or a built-in symbol), imports from bookmarks or Arc, and its settings (on or off, shown or hidden, side, width, browsers, tab-strip takeover);
- open tabs in browsers with the Tabs extension: list, open, switch, move, mute, duplicate, reload, navigate, move to a new window, close, close others, close below (the last two leave saved links' tabs open);
- a browser's tab helper (the Sidebar page's Set Up);
- Sync: the folder, what syncs, and off;
- the tour: what was seen, showing it, and putting it back.

The app keeps its log in memory only, so the command can't read it. A few sidebar actions still need the sidebar itself: opening a saved link so it holds its tab, Back to Saved Page, and Save This Page Here.

```sh
betterlink sidebar list                                       # every Sidebar Profile, with ids
betterlink sidebar add-link --url https://mail.google.com --to favorites
betterlink sidebar add-folder --name Reading
betterlink sidebar icon set 3f2a --emoji 📚                   # a folder's icon: an emoji, or --symbol star.fill
betterlink sidebar move 3f2a --to favorites --position 1      # the first 4+ characters of an id are enough
betterlink sidebar profiles assign --profile Work --browser "Google Chrome" --browserProfile "Profile 1"
betterlink sidebar settings set --side left --width 300
betterlink tabs list
betterlink tabs close-others --tab 1234
betterlink tabs extension                                     # where the Tabs extension is, for Load unpacked
betterlink tabs setup --browser "Google Chrome"               # set up a browser's tab helper, as the Sidebar page does
betterlink sync set --folder ~/Dropbox/betterlink             # sync through a folder your cloud drive keeps in sync
betterlink tour status                                        # every step of the tour, with the command that does it
```

The command ships inside the app at `betterlink.app/Contents/Helpers/betterlink`. **Agents › Install Command** in the window links it into `~/.local/bin`, creating that folder if needed (it never replaces a file, or a link that isn't betterlink's). Or link it yourself, using wherever betterlink.app is (usually `/Applications`):

```sh
mkdir -p ~/.local/bin
ln -s /Applications/betterlink.app/Contents/Helpers/betterlink ~/.local/bin/betterlink
```

If your shell then can't find `betterlink`, `~/.local/bin` isn't on your PATH. Add `export PATH="$HOME/.local/bin:$PATH"` to `~/.zshrc`, or run the command by its full path.

```sh
betterlink status                                    # settings folder, counts, fallback, browsers
betterlink rules list                                # every rule in order, and which rules for other profiles come first
betterlink rules profiles                            # the profiles that have rules, as the Link Rules page lists them
betterlink rules list --profile Work                 # one profile's rules, numbered by their place in the full order
betterlink rules add --kind domain --pattern example.com --profile Work
betterlink test https://app.example.com/billing      # where it would open, and why
betterlink keys add --keys control,command --profile Work   # hold ⌃⌘ to open in Work
betterlink test https://example.com --keys control,command  # as if ⌃⌘ were held
betterlink fallback set --browser Brave --profile Personal
betterlink config check                              # type errors in config.ts, exactly as the app sees them
betterlink --llms                                    # the full command list, for agents
betterlink skills add                                # installs one skill per command group for your agents
```

How it works:
- It is built with [incur](https://github.com/wevm/incur) and compiled with Bun.
- Every command calls the app's own binary (`Betterlink agent <command> '<json>'`), so each check and each write uses the code the app routes with.
- Writes are locked against the app's own, and a running betterlink picks up changes at once.
- The command never touches the network: incur's update check is off.
- Output is TOON by default, compact and agent-friendly. Use `--json` for JSON.

## Design

The window follows betterlink's design system: `Design/tokens.json` holds the colours (light and dark), type, spacing, radii, sizes and shadows, and is the same file as the "betterlink" Design System artifact. `make tokens` turns it into `Sources/Betterlink/DesignTokens.swift`; `make test` fails if that file is out of date. Every control (buttons, fields, selects, toggles, the sidebar) is drawn from these tokens in `Sources/Betterlink/Controls.swift` and `Components.swift`. The app icon is drawn from code by `scripts/make-icon.swift`, which `make build` turns into `AppIcon.icns`.

## Develop

See [CONTRIBUTING.md](CONTRIBUTING.md) for the toolchain and the rules for testing without touching your real settings. Report security problems privately, as [SECURITY.md](SECURITY.md) describes.

```sh
make test       # fetches the pinned TypeScript compiler, checks design tokens and the tour, then runs swift test
make tour       # after editing Tour/tour.json: regenerates the tour's Swift registry and checks it covers the app
make build      # dist/betterlink.app, with the command inside; needs Bun 1.4.4 (https://bun.sh)
make test-cli   # builds, then runs the command's tests against the built app
dist/betterlink.app/Contents/MacOS/Betterlink --test 'https://app.example.com'   # prints the decision; opens nothing
```

For screenshots and manual checks, these environment variables change how betterlink starts, in any build (`open -n --env NAME=value dist/betterlink.app`):

| Variable | Effect |
|---|---|
| `BETTERLINK_HOME` | Settings folder to use instead of the standard one. Use a temporary folder so tests never touch your real rules. This Mac's own settings (the sidebar, Sync, the toast) are separate for each such folder too. |
| `BETTERLINK_TABS_EXTENSION_DIR` | Folder betterlink keeps the Tabs extension in, instead of the standard one (under `BETTERLINK_HOME`, `tabs-extension` in there). |
| `BETTERLINK_APPEARANCE` | `light` or `dark`, regardless of the system setting. |
| `BETTERLINK_PAGE` | Page to open: `rules`, `profiles`, `permissions`, `config`, `general`, `log`, `about`. |
| `BETTERLINK_SYNC_DEVICE` | Tests only: this copy's sync device id, with its own sync settings, so two copies on one Mac sync like two Macs. |
| `BETTERLINK_TRACE` | `1` logs sidebar diagnostics to `trace.log` in the settings folder: how far the sidebar trailed each window drag, each show and hide, each word on the focus from macOS and from the extension, each pairing the focus made or lost, how long each read of the window server's list took, and each closed window with what said it was gone. |
| `BETTERLINK_SHEET` | `rules` or `profiles` opens that editor sheet. |
| `BETTERLINK_TOUR` | What the window does the next time it opens: `welcome` shows the first-run tour, `new` shows What's New if anything is new (nothing is before the first run is over), `off` shows neither. `welcome` and `new` act once. |
| `BETTERLINK_TEST_LINK` | Pre-fills the link tester. |

`Tests/BetterlinkCoreTests/Fixtures/url-vectors.json` comes from `node scripts/gen-url-vectors.mjs`. Node's `URL` follows the same standard as Brave.
