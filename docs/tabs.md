# Sidebar and tabs

betterlink keeps a live mirror of every open tab in your Chromium browsers, in true realtime, both ways, and shows it in the sidebar beside the browser window. Open or close a tab in the browser and the sidebar changes in the same instant; open, focus or close a tab from the sidebar and the browser does it immediately. No polling anywhere. The Sidebar page holds the sidebar's settings and browser setup; it doesn't list tabs itself.

The extension runs a short list of tab commands: open, focus, close (one or several), move, mute, duplicate, reload, send to an address, and move to a new window.

## How it works

```
 Browser (Chrome, Dia, Brave, Arc, Edge…)
   browser-extension/background.js  ── chrome.tabs / chrome.windows events, pushed as they fire
        │  native messaging: stdio, 4-byte length + JSON   (connectNative keeps the worker alive)
        ▼
 betterlink-tabhost  (Contents/Helpers; one process per browser, launched by the browser)
        │  Unix socket, newline-delimited JSON
        │  ~/Library/Application Support/betterlink-tabs/sockets/<browser>-<pid>.sock
        ▼
 betterlink (sidebar)   ── SyncHub: watches the socket folder with kqueue, one TabStore per browser
```

- **Browser to app.** The extension subscribes to every tab and window event (`onCreated`, `onRemoved`, `onUpdated`, `onMoved`, `onActivated`, `onAttached`, `onDetached`, `onReplaced`, window create/remove/focus) and forwards each one the moment Chrome fires it, stamped with a sequence number and the browser's clock.
- **App to browser.** The app writes a command to the socket (`open`, `close`, `closeMany`, `activate`, `move`, `mute`, `duplicate`, `reload`, `navigate`, `newWindow`, `snapshot`; `Command.Op` in `Messages.swift`, and a test keeps that list equal to the extension's `OPS`); the host frames it onto the browser's stdin; the extension runs the real `chrome.tabs` call and acks. The ack of an `open` or a `duplicate` names the tab it made. The resulting change comes back through the normal event path, so the app has one source of truth.
- **Old and new copies work together.** The extension's hello lists the commands it runs (`ops`, since 0.2.0). The sidebar offers an action only when the connected copy can do it (`BrowserSession.can`), so an unpacked copy that hasn't been reloaded keeps working with what it has: open, close, focus.
- **Either side can start first.** Each host listens on its own socket; the app watches the folder with kqueue (inotify on Linux) and connects the instant a socket appears. On connect the host asks the extension for a full snapshot. When the browser quits, the host sees EOF, removes its socket and the app drops that browser. A crashed host's leftover socket is removed by the app.
- **Self-healing.** `TabStore` is a pure reducer over the event stream. A gap in sequence numbers makes it ask for a fresh snapshot.
- **Multiple browsers at once.** Each browser (and each profile) runs its own host, so the app follows Chrome and Brave at once and the sidebar shows whichever is in front. The host names itself after the app that launched it.

The only timer in the system is the extension's reconnect backoff (1s doubling to 60s) for when the host is not installed.

## Measured

`make test-tabs` runs the real extension bridge (against a simulated `chrome.tabs`), the real `betterlink-tabhost` binary and the real app-side `SyncHub`:

```
browser->app: 1.0 ms; app->browser->app: 1.7 ms; host-measured event latency: 0.34 ms
```

The terminal view (`betterlink-tabs`) prints the event latency (browser fired it → app applied it) for every event; with `--json` it also reports the command round trip.

## Layout

```
browser-extension/           MV3 extension (bridge.js is pure and unit tested)
Sources/TabSyncCore/         protocol, TabStore reducer, framings, SyncHub, HostRegistration (Foundation only)
Sources/betterlink-tabhost/  native messaging host, shipped in Contents/Helpers
Sources/betterlink-tabs/     terminal view: prints events with latency; open, close, activate, move, mute, duplicate, reload, navigate, list
Sources/Betterlink/SidebarPage.swift  the Sidebar page
Sources/Betterlink/TabsModel.swift  the app side of the tab sync
Tests/TabSyncCoreTests/      reducer, framings, host registration, pinned extension id
e2e/                         full pipe test
```

## Try it

1. Build and run betterlink (CONTRIBUTING.md: use a `BETTERLINK_HOME` temp folder).
2. Sidebar page › Browsers › **Set Up** next to the browser. That writes one file, `NativeMessagingHosts/com.wkoutre.betterlink.tabs.json`, in that browser's data folder, pointing at this betterlink's `Contents/Helpers/betterlink-tabhost`. **Uninstall** deletes it.
3. In that browser: chrome://extensions › Developer mode › Load unpacked › `browser-extension/`.

The extension's id is its Chrome Web Store item id, `gjjllnebeeegbipppiclhlomdppbnljh`. The `key` in its manifest is that item's public key (checked by a test), so an unpacked copy has the same id and `allowed_origins` matches both. A registration written for another id shows as "Points elsewhere": press Set Up Again. Nothing starts until the Sidebar page is opened or the sidebar is turned on.

Tests: `make test` covers TabSyncCore; `make test-tabs` runs the extension bridge tests and the full-pipe e2e.

## The sidebar

Sidebar page › Sidebar › **Show the sidebar** puts a panel flush against the front browser window's left or right edge, the window's full height, showing that window's tabs. It follows the window as it moves, resizes, changes focus, minimises or goes full screen (hidden there), and hides when another app is in front. While betterlink's own window is in front it stays beside the browser window but drops beneath betterlink's windows, so the Side setting previews live. On quit, betterlink gives the space it took back to every window it narrowed.

- **Tracking** (`Sidebar/WindowTracker.swift`) is event-driven: NSWorkspace says which app is in front; an `AXObserver` on that app reports focused-window changes, moves and resizes. During a live drag the frame comes from the window server, not the browser: on every mouse-drag event (a global mouse monitor, which needs no permission) and once per display refresh until mouse up. A window is "settled" 150 ms after its last move with the mouse up; only then is it narrowed to make room. Needs the Accessibility permission; the page asks for it.
- **Which browsers** (Sidebar page › Browsers): every installed Chromium browser by default. Safari isn't offered until its extension ships. With several open, the sidebar follows whichever attached browser is in front.
- **Width**: drag the edge between the sidebar and the window (200 to 440 pt). The pair keeps its outer edges, and the window stops at the browser's own minimum (`SidebarGeometry.resized`, unit tested). `betterlink sidebar settings set --width` does it too.
- **Keyboard** (`SidebarRows`, unit tested): Down from the New Tab field goes to the rows. Up and Down move, Left and Right close and open a folder (or move along the Favorites), Return opens, Delete closes the row's tab (a saved link with no tab is removed, a folder deleted), Escape goes back to the browser.
- **Show and hide**: Control-Option-S (change it under Sidebar › Show or hide), or Show/Hide Sidebar in the menu bar menu. Hiding gives the window its space back. The shortcut is registered only while an attached browser is in front.
- **Favorites and folders**, like Arc and Dia: each Sidebar Profile has a grid of Favorites and nested folders of saved links above the window's open tabs. Drag a tab onto the grid or a folder (or use its menu) to save it. Saved in sidebar.json in the settings folder.
- **A saved link keeps its tab** (`SidebarHolds.swift`, unit tested), like a pinned tab in Arc and Dia. Click a saved link and the tab it opens is that link's tab from then on, wherever you go inside the site: the tab stays on the link's row instead of dropping into the tab list, and the next click switches back to it instead of opening the site again. That is what makes a link to mail.google.com work, since the page moves on to its inbox address at once. When the tab is on another page than the saved one, the row shows "/ page title" after the name and a back arrow that returns the tab to the saved page; right-click has Back to Saved Page, Save This Page Here (the link now saves the page you are on), Close Tab and Copy Link. A tab that merely happens to be at a saved link's address also shows with the link, while it stays there. Saving a tab makes it the new link's tab. Held tabs come back to their links after the browser restarts: where each one was is kept in betterlink's own preferences on this Mac (never the synced settings folder), and the restored tabs are matched by address for the first minute. Closing a held tab yourself closes the link; quitting the browser doesn't. Tabs in private windows are never held or remembered.
- **A tab's right-click menu** has what the browser's own tab strip offers, because the sidebar stands in for it: Add to Favorites, Save to Folder, Copy Link, Reload, Duplicate, Mute or Unmute Tab, Move to New Window, Close Tab, Close Other Tabs, Close Tabs Below. A tab playing sound shows a speaker; click it to mute. Close Other Tabs and Close Tabs Below leave saved links' tabs alone.
- **Import** (Sidebar page › Import; `SidebarImport.swift`, unit tested): Import from Arc reads Arc's own sidebar file on this Mac (`~/Library/Application Support/Arc/StorableSidebar.json`) and makes a Sidebar Profile from each Space, with its Favorites, pinned tabs and folders; Today tabs are left out. Import Bookmarks reads a Chromium browser profile's `Bookmarks` file, or a bookmarks.html export from any browser, into one closed folder of the Sidebar Profile you pick. Only web addresses are taken, at most 5,000 links at a time, and nothing is fetched. Importing twice adds a second copy. The Arc reader was written from descriptions of the file's format and has not yet been checked against a real Arc install; if Arc's file doesn't fit, the import says so and changes nothing.
- **Icons for saved links**: a link saved from a tab keeps that tab's icon. An imported link has none, so it shows the first letter of its name until its page has been open once; then it keeps the page's icon.
- **Drag and drop** (`SidebarProfile.place(_:at:)`, unit tested): drag favorites, saved links and folders to reorder them; drag any of them into or out of folders, at any depth, or between the Favorites grid and the folders (a link becomes a favorite and back). Drag a tab onto a spot to save it there. A line shows where it will land; dropping on a folder's middle puts it inside. A folder never goes into itself or the grid. Right-click: Move Up, Move Down, Move to…. Delete happens at once with Undo at the bottom for 6 seconds (a folder with things in it asks first); Undo puts back only what was deleted, where it was. A drop that wouldn't move anything (a folder into itself) shows no line and does nothing. Places to drop for the first Favorite and for the end of the saved items show only during a drag. Not yet: selecting several rows, and moving rows from the keyboard.
- **Reordering tabs**: drag a tab in the sidebar's tab list before or after another to move it there in the browser's own tab order (the extension's `move`, 0.2.0). Only tabs of the same window, and pinned tabs only among pinned ones (the browser keeps them first); a drop next to itself does nothing.
- **Sidebar Profiles**: the ⚙ beside the Sidebar Profile's name at the top of the sidebar picks which Sidebar Profile the window's browser profile shows, makes a new one, renames or deletes this one (deleting asks first), and opens these settings (Sidebar Settings…). The + beside it makes a folder. A profile linked to nothing is shown for every browser profile not linked elsewhere.
- **Taking over the tabs** (on by default): when the sidebar binds to a Chromium window, the browser's own tab strip is switched to vertical tabs and collapsed (Chrome 158: View › Show Tabs Vertically, Collapse Vertical Tabs), through the browser's menu with Accessibility: only those exact items of the View menu, never another menu (History, Bookmarks and Window items are titled by web pages), only once the window is the browser's focused one and only when not already set. The sidebar sits beside the collapsed column, on either side, and never covers it (Nick: "it shouldn't overlap on top of (and effectively hide) the vertical tabs"). Each window is taken over once; switching apps and back does nothing again. Turning the setting off leaves the browser's tabs as they are (View › Show Tabs Vertically switches them back). On by default because Nick asked for the sidebar to take over tab management. No browser has an extension API to hide its tabs.
- **Motion**: every interaction in the sidebar animates briefly (ease-out, 0.12–0.18 s): folders open and close with their contents fading in, rows and favorites appear and disappear, hover and selection highlights fade, buttons dip when pressed, and the panel fades in and out. With Reduce Motion on (System Settings › Accessibility › Display), nothing animates. Showing and hiding is one slide with the window (`SidebarSlide`, unit tested): the sidebar's outer edge stays put while its inner edge and the window's edge move together over 0.22 s, easing in and out, so the seam never opens; at the end of a hide the window fills its tile. The window is resized through Accessibility each frame and the sidebar shows only up to where the window really is, so the seam stays tight even when the browser lags. Reduce Motion: at once. Switching apps still fades the sidebar (`Fade`, on its own timer). Diagnostics: with `BETTERLINK_TRACE=1`, each window drag logs how far the sidebar trailed the window, and each show and hide is logged, to `trace.log` in the settings folder.
- **Placement** (`TabSyncCore/SidebarGeometry.swift`, unit tested) is pure math over Cocoa frames: the window and its sidebar act as one window. When a window comes to rest snapped to a half, third, quarter or the whole screen, it is narrowed so the pair fills exactly that tile; placed by hand too close to the edge, it gives up only what is missing. Never while you drag it. Turning the sidebar off gives the space back. If the browser refuses, the panel covers the window's edge.
- **Snapping the sidebar itself**: a window-snapping tool (or anything using Accessibility) that resizes the sidebar to a tile fills that tile with the browser and sidebar together, the sidebar keeping its width; one that only moves it (or changes only its height) moves the browser along at the same width. Moves macOS makes when displays change are ignored.
- **Which tabs** (`WindowMatch.find`, unit tested): the browser session whose process is the front app, then the one window that browser reports as focused; failing that, the window at the same place on screen whose active tab's title the window title starts with. It never guesses: a click in the sidebar switches, closes and opens tabs, so the wrong window's tabs are worse than none. A window the extension doesn't report (an Incognito window without Allow in Incognito, or a browser profile without the extension) shows one line saying so instead of another window's tabs.
- **Profiles**: each browser profile runs its own copy of the extension, so each is its own session. The extension keeps a random id in its own `chrome.storage.local` (the `storage` permission); betterlink finds that id in `<profile folder>/Local Extension Settings/<extension id>/` to learn which profile a session is, and reads the profile's name from the browser's `Local State`. For the sidebar's color it also reads the profile's `Preferences` (a custom theme's color) and the frame color in `Local State`, again on the next tab change at least 30 s later, so a change in the browser shows up. It reads only those files, and only those fields; never page data. The window in front is the browser's focused window (`windows.onFocusChanged`); its frame is the fallback.
- **Icons** come from the browser's own favicon cache through the extension (`favicon` permission), as data: URLs. betterlink itself fetches nothing.
- The panel is non-activating: clicking it never takes the browser out of the front.

## Browser coverage

- Chromium family (Chrome, Brave, Edge, Arc, Vivaldi, Dia): this extension as is. Each browser keeps its own `NativeMessagingHosts` folder under the data folder betterlink already knows (`Browser.dataFolder`).
- Firefox: same design; it needs `browser_specific_settings`, a host manifest under `~/Library/Application Support/Mozilla/NativeMessagingHosts`, and `browser.*` (the events are the same).
- Safari: a Safari Web Extension inside the app bundle, talking to the app through `SFSafariApplication`/app groups instead of a stdio host. Same events, different transport.

## Known gaps (prototype)

- Events that fire while no app is connected are not queued; the snapshot on connect covers them.
- A tab event that fires during the few ms a snapshot is being collected can be lost; the next event's sequence number is still consecutive, so this one case does not self-heal yet. Fix: collect the snapshot inside the extension's own event queue.
- Incognito windows are only visible if the extension is allowed in incognito; the sidebar says it can't see one that isn't.
- A held tab is found again after a browser restart by its address. A tab the browser restores later than a minute after starting, or at another address, goes back to the tab list.
- Reopening a closed window (History › Recently Closed) brings its tabs back with new ids, so saved links there take their tabs back only where the address still matches.
- The extension is not in any store; it is loaded unpacked.

## Where this could go

- A floating, always-on-top sidebar window and a hotkey to summon it.
- Routing: open a link in the window that already has its site, or focus an existing tab instead of opening a duplicate.
- Firefox and Safari ports (see Browser coverage).
