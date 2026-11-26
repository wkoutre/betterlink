# The tour (design)

Status: built. `Tour/tour.json` is the list of steps. `scripts/gen-tour.py` turns it into `Sources/BetterlinkCore/TourRegistry.swift` and checks it against the app. `Sources/BetterlinkCore/Tour.swift` decides which steps to show; `Sources/Betterlink/Tour/` draws them.

The tour is how betterlink introduces itself. It is one framework with three ways in:

1. **The first run.** The first time someone opens the window on a Mac that has never finished or skipped the tour. That includes a Mac that used betterlink before the tour existed: after the update that brings the tour, it shows the next time the window is opened, once.
2. **What's New.** After an update, only the steps that were added or changed since this Mac last saw the tour.
3. **A replay.** The whole tour, or one topic, whenever someone asks: **About › Tour**, the menu bar's **Show the Tour…**, or `betterlink tour show`.

All three show the same steps, drawn by the same views, so a new feature's step looks and reads like the first run did.

## What a person sees

A step fills the window: a tile, a title, two or three sentences saying what the thing is for, one control that does it (the same control its page has, with its live status), and the `betterlink` command that does the same.

The first run shows the essential steps one after another, at most six: what betterlink is, making it the default browser, profiles, the fallback, and a first Link Rule. Then it offers the other topics as cards (modifier keys, the sidebar, Sync, the command, and so on) to open or leave. **Skip Tour** is on every step, and Esc does the same. So does closing the window: the tour is over, and the window opens on its pages the next time.

What's New never opens by itself. When there is something new, the window shows one line above its page ("New in betterlink: …" with **Show Me** and a dismiss button), and the menu bar item reads **What's New…**. Showing it, dismissing it, finishing the tour and skipping the tour all count as caught up.

A step that doesn't apply to this Mac is left out: the sidebar steps need a Chromium browser, the Dia step needs Dia. It also stays unseen, whatever is finished or skipped, so the day that browser is installed its steps are offered under What's New.

## The rules it follows

These come from how comparable Mac apps onboard (the notes at the end) and from Apple's guidelines. They are why the tour is shaped the way it is; keep them when changing it.

- **Never on a link click.** betterlink's job is to get out of the way of a link. The tour shows only when the person opens the window themselves, never when the window opens to report a problem or was asked for a page, and never when betterlink was started by macOS at login.
- **The first run opens once.** If it is skipped, or its window is closed, it does not come back by itself.
- **An update never opens a window.** What's New is offered, not shown.
- **Ask where the reason is.** Each permission has its own step that says what it is for before the button that asks. The tour asks macOS for nothing by itself: every prompt follows a click on a button that says what will happen.
- **Required and optional are different.** Only the default browser is needed. Everything else can be left for later, and the tour says so.
- **Finish by doing.** A step holds the real control, not a picture of it. What is set in the tour is set.
- **Always a way back.** Every step stays under About, and every topic names the page where its settings live.
- **Everything has a command.** Each step shows the `betterlink` command that does the same, or says in one line why none can (a macOS permission only a person can grant).

## A step

```json
{
  "id": "open-at-login",
  "revision": 1,
  "title": "Open betterlink at login",
  "body": "Start betterlink when you log in, so the first link after a restart opens without a pause and held keys are seen in time. macOS lists it under Login Items.",
  "status": "openAtLogin",
  "control": "openAtLogin",
  "cli": "betterlink login set --enabled on",
  "covers": { "commands": ["login"], "permissions": ["login-item"], "settings": ["Pages.model.opensAtLogin"] }
}
```

| Field | Meaning |
|---|---|
| `id` | What betterlink remembers the person saw. Never changed and never reused. |
| `revision` | Starts at 1. Raising it shows the step again, under What's New, to people who saw the earlier one. |
| `changed` | One sentence on what is different, shown with a raised revision. Required from revision 2 on. |
| `title`, `body` | The words. Lengths and punctuation are checked (see below). |
| `control` | The control the step holds, by name. A new name must be drawn in `TourControls.swift` before the app builds. |
| `status` | The live state shown beside the control (Allowed, Not Set Up, and so on), by name. |
| `requires` | A condition this Mac must meet for the step to apply (`sidebarBrowser`, `dia`). |
| `cli` / `cliWhy` | The command that does the same, or why there is none. One of the two is required when the step has a control. |
| `covers` | What the step accounts for: `pages`, `commands` (a command group), `permissions`, `settings`. The coverage check reads these. |

A topic groups steps: `id`, `title`, `summary` (its card), `symbol` and `tile` (a colour from `Design/tokens.json`), `tier` (`essential` is in the first run, `more` is offered after it), and `page` (where its settings live).

## Adding or changing a step

When to do it is in [AGENTS.md](../AGENTS.md#the-tour). How:

1. Edit `Tour/tour.json`. A new feature gets a new step in the topic it belongs to, or a new topic with tier `more`. Only something nobody can use betterlink without belongs in `essential`.
2. If the step needs a control or a status that doesn't exist yet, name it in the JSON and draw it in `Sources/Betterlink/Tour/TourControls.swift`. The build fails until every name is handled: the switches there have no default case.
3. Run `make tour`. It rewrites `TourRegistry.swift` and reports anything the tour doesn't cover.
4. If the step's command is new, add it to `cli/src/bin.ts` first. A step can't name a command or an option the CLI doesn't have.
5. `make test`.

To show an existing step again after its feature changed: raise `revision` by one and write `changed`. A wording fix needs neither.

To remove a step: delete it and add its id to `retired`.

## What is checked for you

`make test` runs these before `swift test`, and CI's required `swift-test` check runs `make test`. They read the source as text, so they need no build.

| Check | Fails when |
|---|---|
| The registry is current | `TourRegistry.swift` doesn't match `Tour/tour.json` (run `make tour`). |
| Every page has a step | A case of `RootView.Page` is in no step's `covers.pages` and not under `exempt.pages`. |
| Every command group has a step | A group of agent commands (`rules`, `sidebar.settings`, …) is in no `covers.commands` and not exempt. |
| Every setting has a step | A `Toggle`, picker, slider, stepper, colour or swatch picker, or shortcut recorder on a page is bound to something no step covers. |
| Every permission has a step | The source asks macOS or a browser for something (default browser, Full Disk Access, Accessibility, Automation, a login item, native messaging, an extension and what its manifest asks for, a file or folder panel) that no step covers. An API for a prompt betterlink doesn't use today (camera, notifications, screen recording, input monitoring, the local network, Touch ID, …) fails too, until it has an entry and a step. |
| Nothing is stale | A step or an exemption names a page, command, setting or permission the app no longer has. |
| Commands are real | A step's `cli` names a command or an `--option` that `cli/src/bin.ts` doesn't define. |
| The writing rules | A title over 48 characters, a body under 60 or over 330, a dash used as punctuation, an exclamation mark, a missing full stop, more than six essential steps, more than six steps in a topic. |
| Ids are never reused | A step uses an id listed under `retired`. |
| The steps fit the window | `TourLayoutTests`: a step is taller than the window as it opens. |
| What the tour decides | `TourTests`: which steps the first run, What's New and a replay show, and what counts as seen. |
| When the tour comes up | `TourModelTests`: only when the person opens the window, once; a closed window ends it; What's New never opens by itself; what a command asked for waits, then expires. |

The `tour` check on every pull request (`.github/workflows/tour.yml`, `scripts/check-tour-pr.py`) adds what only a pull request shows:

- A PR that changes what ships (`Sources/`, `cli/src/`, `browser-extension/`, `Info.plist`, the entitlements) changes `Tour/tour.json`, or its description says on a `Tour:` line why the tour stays as it is. "Tour: none" with no reason fails.
- A step's `revision` never goes down, and a raised one has a new `changed` sentence.
- A removed step's id is added to `retired`.

It also leaves a note, without failing, when a step was reworded or its control, command or condition changed and its revision stayed the same, and names each new exemption so a reviewer sees it.

## What is left to judgment

A script can tell that a new page has no step. It can't tell that a new command joined a group that already has a step, that a change inside an existing page is worth showing someone again, or that a step's words no longer match what the control does. Those are the rules in [AGENTS.md](../AGENTS.md#the-tour), which coding agents load on every session and reviewers check a PR against, and the `Tour:` line makes each PR answer them out loud.

## Remembering what was seen

Per Mac, in betterlink's own preferences (a separate set for each `BETTERLINK_HOME`): `tour.seen` maps a step's id to the revision that was shown, and `tour.welcomed` says the first run was finished or skipped. A step counts as seen once it has been on screen. Finishing, skipping or dismissing marks every step that applies to this Mac seen, so the next What's New holds only what is added afterwards. Nothing about the tour syncs between Macs or leaves the Mac.

## The command

```sh
betterlink tour status                 # every topic and step, what was seen, what is new, each step's command
betterlink tour show                   # open the window on the whole tour
betterlink tour show --topic sidebar   # or on one topic
betterlink tour new                    # open the window on What's New
betterlink tour done                   # mark everything seen without showing it (or --topic, --step)
betterlink tour reset                  # forget everything, so the first run comes back (or --topic, --step)
```

`tour status` is also the list an agent setting betterlink up can work through: each step carries the command that does what its control does.

`tour show` and `tour new` open the window at once when betterlink is running. When it isn't, what was asked for waits ten minutes for the person to open betterlink, then is forgotten: a command never makes a window appear later, by itself. A step or topic is named with `--step` or `--topic`; a bare word after the command is refused.

## For development

`BETTERLINK_TOUR` changes what the window does when it next opens, in any build: `welcome` shows the first run, `new` shows What's New if anything is new (nothing is before the first run is over), `off` shows neither (scripts that open the window use it). `welcome` and `new` act once. With `BETTERLINK_HOME` set to a temporary folder the tour starts from nothing, as on a new Mac.

## What other apps do

Looked at in November 2026: Rectangle, Ice, Loop, AltTab, Finicky, Browserosaurus, Velja, Choosy, SupaSidebar, Alfred, Raycast, Arc and Dia, with Apple's Human Interface Guidelines on onboarding and on requesting permission, and the WhatsNewKit, TipKit and Sparkle documentation.

- The apps people praise use one small window, not a wizard: a short welcome, then one row or screen per permission with what it is for, a button, and a status that turns green by itself.
- Accessibility has no system dialog to answer. The pattern that works: explain, open System Settings on the right pane, and watch for the grant while the screen is visible.
- Automation is asked per app, and only while that app is running. Full Disk Access can't be asked for at all, only pointed to.
- Good ones separate required from optional, let everything be skipped, and keep a permanent way back to the same screens.
- The common complaints: an app that quits when its permission window closes, an account before first use, boxes ticked in advance, a What's New window on every update, an update prompt in the middle of work, and reminders that repeat.
- For a tool whose job is to pass a click along quickly, the last three matter most. That is why What's New here is a line in a window the person already opened.
