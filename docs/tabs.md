# Tabs (preview)

betterlink keeps a live mirror of every open tab in your Chromium browsers, in true realtime, both ways, and shows it in the sidebar beside the browser window. Open or close a tab in the browser and the sidebar changes in the same instant; open, focus or close a tab from the sidebar and the browser does it immediately. No polling anywhere. The Tabs page holds the sidebar's settings, Sidebar Profiles and browser setup; it doesn't list tabs itself.

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
Sources/Betterlink/TabsPage.swift  the Tabs page
Tests/TabSyncCoreTests/      reducer, framings, host registration, pinned extension id
e2e/                         full pipe test
```

## Try it

1. Build and run betterlink (CONTRIBUTING.md: use a `BETTERLINK_HOME` temp folder).
2. Tabs page › Browsers › **Set Up** next to the browser. That writes one file, `NativeMessagingHosts/com.wkoutre.betterlink.tabs.json`, in that browser's data folder, pointing at this betterlink's `Contents/Helpers/betterlink-tabhost`. **Remove** deletes it.
3. In that browser: chrome://extensions › Developer mode › Load unpacked › `browser-extension/`.

The extension's id is pinned by the `key` in its manifest (`nakiifbonhngpkpekakimjfgkbbbnjoe`, checked by a test), so `allowed_origins` matches every unpacked copy. Nothing starts until the Tabs page is opened or the sidebar is turned on.

Tests: `make test` covers TabSyncCore; `make test-tabs` runs the extension bridge tests and the full-pipe e2e.

## The sidebar

Tabs page › Sidebar › **Show the sidebar** puts a panel flush against the front browser window's left or right edge (or whichever side has room), the window's full height, showing that window's tabs. It follows the window as it moves, resizes, changes focus, minimises or goes full screen (hidden there), and hides when another app is in front. While betterlink's own window is in front it stays beside the browser window but drops beneath betterlink's windows, so the Side and Width settings preview live. On quit, betterlink gives the space it took back to every window it narrowed.

- **Tracking** (`Sidebar/WindowTracker.swift`) is event-driven: NSWorkspace says which app is in front; an `AXObserver` on that app reports focused-window changes, moves and resizes. During a live drag the frame comes from the window server, not the browser: on every mouse-drag event (a global mouse monitor, which needs no permission) and once per display refresh until mouse up. A window is "settled" 150 ms after its last move with the mouse up; only then is it narrowed to make room. Needs the Accessibility permission; the page asks for it.
- **Which browsers** (Tabs page › Sidebar › Attach to): every installed Chromium browser and Safari by default. With several open, the sidebar follows whichever attached browser is in front.
- **Show and hide**: Control-Option-S (change it under Sidebar › Show or hide), or Show/Hide Sidebar in the menu bar menu. Hiding gives the window its space back. The shortcut is registered only while an attached browser is in front.
- **Favorites and folders**, like Arc and Dia: each Sidebar Profile has a grid of Favorites and nested folders of saved links above the window's open tabs. Drag a tab onto the grid or a folder (or use its menu) to save it. Saved in sidebar.json in the settings folder.
- **A saved link keeps its tab** (`SidebarHolds.swift`, unit tested), like a pinned tab in Arc and Dia. Click a saved link and the tab it opens is that link's tab from then on, wherever you go inside the site: the tab stays on the link's row instead of dropping into the tab list, and the next click switches back to it instead of opening the site again. That is what makes a link to mail.google.com work, since the page moves on to its inbox address at once. When the tab is on another page than the saved one, the row shows "/ page title" after the name and a back arrow that returns the tab to the saved page; right-click has Back to Saved Page, Save This Page Here (the link now saves the page you are on), Close Tab and Copy Link. A tab that merely happens to be at a saved link's address also shows with the link, while it stays there. Saving a tab makes it the new link's tab. Held tabs come back to their links after the browser restarts: where each one was is kept in betterlink's own preferences on this Mac (never the synced settings folder), and the restored tabs are matched by address for the first minute. Closing a held tab yourself closes the link; quitting the browser doesn't. Tabs in private windows are never held or remembered.
- **A tab's right-click menu** has what the browser's own tab strip offers, because the sidebar stands in for it: Add to Favorites, Save to Folder, Copy Link, Reload, Duplicate, Mute or Unmute Tab, Move to New Window, Close Tab, Close Other Tabs, Close Tabs Below. A tab playing sound shows a speaker; click it to mute. Close Other Tabs and Close Tabs Below leave saved links' tabs alone.
- **Import** (Tabs page › Import; `SidebarImport.swift`, unit tested): Import from Arc reads Arc's own sidebar file on this Mac (`~/Library/Application Support/Arc/StorableSidebar.json`) and makes a Sidebar Profile from each Space, with its Favorites, pinned tabs and folders; Today tabs are left out. Import Bookmarks reads a Chromium browser profile's `Bookmarks` file, or a bookmarks.html export from any browser, into one closed folder of the Sidebar Profile you pick. Only web addresses are taken, at most 5,000 links at a time, and nothing is fetched. Importing twice adds a second copy. The Arc reader was written from descriptions of the file's format and has not yet been checked against a real Arc install; if Arc's file doesn't fit, the import says so and changes nothing.
- **Icons for saved links**: a link saved from a tab keeps that tab's icon. An imported link has none, so it shows the first letter of its name until its page has been open once; then it keeps the page's icon.
- **Drag and drop** (`SidebarProfile.place(_:at:)`, unit tested): drag favorites, saved links and folders to reorder them; drag any of them into or out of folders, at any depth, or between the Favorites grid and the folders (a link becomes a favorite and back). Drag a tab onto a spot to save it there. A line shows where it will land; dropping on a folder's middle puts it inside. A folder never goes into itself or the grid. Right-click: Move Up, Move Down, Move to…. Delete happens at once with Undo at the bottom for 6 seconds (a folder with things in it asks first); Undo puts back only what was deleted, where it was. A drop that wouldn't move anything (a folder into itself) shows no line and does nothing. Not yet: selecting several rows, and moving rows from the keyboard.
- **Reordering tabs**: drag a tab in the sidebar's tab list before or after another to move it there in the browser's own tab order (the extension's `move`, 0.2.0). Only tabs of the same window; a drop next to itself does nothing.
- **Sidebar Profiles**: the ⚙ beside the Sidebar Profile's name at the top of the sidebar picks which Sidebar Profile the window's browser profile shows, makes a new one, renames or deletes this one (deleting asks first), and opens these settings (Sidebar Settings…). Tabs page › Sidebar Profiles also renames and deletes them. A profile linked to nothing is shown for every browser profile not linked elsewhere.
- **Taking over the tabs** (on by default): when the sidebar binds to a Chromium window, the browser's own tab strip is switched to vertical tabs and collapsed (Chrome 158: View › Show Tabs Vertically, Collapse Vertical Tabs), through the browser's menu with Accessibility: only those exact items of the View menu, never another menu (History, Bookmarks and Window items are titled by web pages), only once the window is the browser's focused one and only when not already set. With the sidebar on the left, the sidebar also covers that collapsed column, measured from the window, so no tab strip shows; the column is measured again after every click, so expanding it or turning vertical tabs off uncovers it. Each window is taken over once; switching apps and back does nothing again. Turning the setting off leaves the browser's tabs as they are (View › Show Tabs Vertically switches them back). On by default because Nick asked for the sidebar to take over tab management. No browser has an extension API to hide its tabs.
- **Motion**: every interaction in the sidebar animates briefly (ease-out, 0.12–0.18 s): folders open and close with the chevron turning and their contents fading in, rows and favorites appear and disappear, hover and selection highlights fade, buttons dip when pressed, and the panel fades in and out. With Reduce Motion on (System Settings › Accessibility › Display), nothing animates.
- **Placement** (`TabSyncCore/SidebarGeometry.swift`, unit tested) is pure math over Cocoa frames: the window and its sidebar act as one window. When a window comes to rest snapped to a half, third, quarter or the whole screen, it is narrowed so the pair fills exactly that tile; placed by hand too close to the edge, it gives up only what is missing. Never while you drag it. Turning the sidebar off gives the space back. If the browser refuses, the panel covers the window's edge.
- **Snapping the sidebar itself**: a window-snapping tool (or anything using Accessibility) that resizes the sidebar to a tile fills that tile with the browser and sidebar together, the sidebar keeping its width; one that only moves it (or changes only its height) moves the browser along at the same width. Moves macOS makes when displays change are ignored.
- **Which tabs** (`WindowMatch.find`, unit tested): the browser session whose process is the front app, then the one window that browser reports as focused; failing that, the window at the same place on screen whose active tab's title the window title starts with. It never guesses: a click in the sidebar switches, closes and opens tabs, so the wrong window's tabs are worse than none. A window the extension doesn't report (an Incognito window without Allow in Incognito, or a browser profile without the extension) shows a short note saying so instead of another window's tabs.
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
- Incognito windows are only visible if the extension is allowed in incognito; the sidebar says so beside one that isn't.
- A held tab is found again after a browser restart by its address. A tab the browser restores later than a minute after starting, or at another address, goes back to the tab list.
- Reopening a closed window (History › Recently Closed) brings its tabs back with new ids, so saved links there take their tabs back only where the address still matches.
- The extension is not in any store; it is loaded unpacked.

## Where this could go

- A floating, always-on-top sidebar window and a hotkey to summon it.
- Routing: open a link in the window that already has its site, or focus an existing tab instead of opening a duplicate.
- Firefox and Safari ports (see Browser coverage).
