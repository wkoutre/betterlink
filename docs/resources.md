# Resource use

What betterlink costs, how to measure it, and what it must not exceed.

```sh
make .build/measure-resources
.build/measure-resources 60 <betterlink pid> <betterlink-tabhost pid>
```

Measure with an isolated build (CONTRIBUTING.md: `BETTERLINK_HOME`, plus `BETTERLINK_TABS_SOCKET_DIR`) against a throwaway browser, with the screen unlocked: a locked screen draws nothing, so it hides what drawing costs.

| | Budget |
|---|---|
| Idle, no browser in front | app under 0.1% of a core, under 1 wakeup a second |
| Quiet browser in front | the same |
| Several quiet browser windows, each with its sidebar | the same |
| Several windows with sidebars, another app in front, tabs changing: paced every 2 s | not measured yet |
| 56 tabs changing their titles twice a second, sidebar hidden | app under 2% |
| Tab host | flat memory, under 1% |

`make check-idle` fails when the built app (its Sidebar page open, so the tab sync runs) or the tab host uses more than 1% of a core or wakes more than 5 times a second with nothing happening. The sidebar and Sync are off in it, so their timers and observers are not covered. CI runs it on every pull request; the limits are loose because CI machines are noisy. It looks three times, 15 s each, and passes on the first look within the limits: a slow machine may still be settling after the launch in the first. A look over the limits prints a `sample` of the app, so the log shows what it was doing.

How it stays there:

- **Tab lists are paced** (`PublishPacer`, unit tested). Opens, closes, moves and switches go on at once. What a tab shows (title, icon) goes at once when quiet and at most 10 times a second under churn, but only while a sidebar is on screen and an attached browser is the front app (`PublishPacer.interval`, unit tested). Otherwise every 2 seconds: with no sidebar on screen, and with sidebars on screen beside their windows while another app is in front, which is most of the day. When a browser comes to the front, what was held back goes on at once.
- **Tab rows are drawn again only when something they show or use changed** (`SkipUnchanged`, `RowKey` in SidebarView): another tab's title isn't such a thing.
- **The host drains its pool per read** (`e2e/host-memory.test.mjs` fails if its memory grows).
- **The extension says nothing** when an update changes nothing the app sees.
- **A sidebar per window adds nothing while nothing changes.** No timer runs for a sidebar at rest. Each is handed what it shows only when its own window's tabs, Browser Profile or held tabs differ (`SidebarLook`, unit tested), so a tab changing in one window redraws no other window's sidebar, and one that isn't on screen is handed nothing. Their places among the windows are checked on app and window events, with one reading of the window list for all of them, and once more 0.3 s later.
- **What kind a window is is read on events only** (`WindowKinds`, unit tested): a window is walked for its tabs when it opens or is named again by an event (its browser's own chrome, a few dozen elements, pages skipped; the walk stops at the first tab), and one that shows none at most five more times over three seconds. A window seen with tabs is not read again.
- **Mouse drags are watched** only while a browser is in front, or until the button comes up after a window moved with it down.
- **The sync rescan** skips this Mac's own file and may run up to 10 s late.
