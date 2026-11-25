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
| 56 tabs changing their titles twice a second, sidebar hidden | app under 2% |
| Tab host | flat memory, under 1% |

`make check-idle` fails when the built app (its Sidebar page open, so the tab sync runs) or the tab host uses more than 1% of a core or wakes more than 5 times a second with nothing happening. The sidebar and Sync are off in it, so their timers and observers are not covered. CI runs it on every pull request; the limits are loose because CI machines are noisy.

How it stays there:

- **Tab lists are paced** (`PublishPacer`, unit tested). Opens, closes, moves and switches go on at once. What a tab shows (title, icon) goes at once when quiet and at most 10 times a second under churn, or every 2 seconds while the sidebar is hidden or no browser is in front.
- **Tab rows are drawn again only when something they show or use changed** (`SkipUnchanged`, `RowKey` in SidebarView): another tab's title isn't such a thing.
- **The host drains its pool per read** (`e2e/host-memory.test.mjs` fails if its memory grows).
- **The extension says nothing** when an update changes nothing the app sees.
- **Mouse drags are watched** only while a browser is in front.
- **The sync rescan** skips this Mac's own file and may run up to 10 s late.
