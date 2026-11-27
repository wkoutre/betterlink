# Sync (design)

Status: built (BetterlinkCore SyncCore, SyncModel, SyncSession, SyncSafety; the app's SyncController and General › Sync). Not built yet: the Link Rules page's mark on a rule whose profile this Mac lacks.

betterlink syncs your settings between Macs through a folder that Dropbox, Google Drive or iCloud Drive already keeps in sync. There's no account, server or API key. You choose what syncs. Two Macs editing at the same time always end up identical, and nothing is lost silently.

## What you choose

Settings › Sync, per Mac:

1. **Sync folder**: any folder (for example `~/Dropbox/betterlink`). Off until one is picked.
2. **Global settings**: one switch. Covers Link Rules, modifier rules, the fallback profile, Show log, and config.ts.
3. **Sidebar Profiles**: a switch per profile. For each synced profile, choose its parts: **Favorites**, **Folders and saved links**, and **Appearance** (name and color).

Never synced (they belong to one Mac): browser profiles themselves (each Mac's own Chrome profiles, found on that Mac), which Sidebar Profile each browser profile shows (Nick: "That is local to each machine"), the sidebar's side, width, shortcut and attach-to list, the tab takeover setting, window positions, the Accessibility grant, browser setup, and the Sync choices above.

A Mac only writes what it has chosen to sync and only applies what it has chosen to receive.

A new Mac: install betterlink, turn on Sync and pick the folder, and the synced settings and Sidebar Profiles arrive. Then open Chrome in any profile and choose its Sidebar Profile from the sidebar's ⚙, as on any Mac. Nothing about another Mac's Chrome profiles carries over. Today that assignment is stored in sidebar.json (each Sidebar Profile's `browserProfiles`). Sync leaves that field out of the device files and never changes it on merge, so it stays per Mac. A Chrome profile with no assignment shows the default Sidebar Profile (the one linked to nothing, such as Primary), as it does now. A profile synced on one Mac and not on another stays local on the second. When you first pick a folder, profiles that other Macs share but this one doesn't have yet are offered with an Add button.

## Files

```
<sync folder>/betterlink-sync/v1/
  devices/<device-id>.json      one per Mac, written only by that Mac
  ```

- Each Mac writes only its own file, so the sync provider never sees two writers on one file and never makes "conflicted copy" files.
- Each file holds that Mac's whole merged state, not just its own edits. So losing one file (a Mac retired, a file deleted) loses nothing that another Mac has seen.
- Files are written whole: a temporary file, then a rename into place. A reader that finds a half-downloaded or unreadable file skips it until the next change.
- `device-id` is a random UUID made once per Mac and kept in that Mac's own settings. The file also names the Mac ("Nick's Mac mini") for the Log.

## The model

Everything that syncs is an **entity** with a stable id: a Link Rule, a modifier rule, a Sidebar Profile, a favorite, a folder, a saved link. Global settings form one entity with fixed field names.

Every field of every entity is stored with a **stamp**:

- **Hybrid logical clock (HLC):** the wall clock in milliseconds, a counter, and the device id. A Mac never issues a stamp lower than any it has seen, so a Mac with a slow clock can't lose to an older edit. Stamps compare by time, then counter, then device id, so two stamps are never equal.
- **Merge:** for each entity and field, the value with the highest stamp wins. Merging is commutative, associative and idempotent. Any set of device files, read in any order, any number of times, gives the same result on every Mac.

Edits made at nearly the same time:

- **Different fields of the same item merge.** One Mac renames a folder while another moves it: both happen.
- **The same field resolves by stamp.** Both Macs rename one folder at once: the later edit wins, on every Mac. The Mac whose value lost lists it under Recently changed by sync, with a Restore button (see Safety). An edit is stamped with when its settings file was saved (rules.json for rules and global settings, config.ts for config.ts, sidebar.json for Sidebar Profiles), so of two saves moments apart on two Macs the later save wins (live: B saving 0.3 s after A won three times out of three).

## Lists and moves

- **Order:** each favorite, folder and saved link has a `position`, a fractional index (a string that sorts between its neighbours). Inserting between two items creates a new key, so two Macs reordering one list both keep their changes instead of overwriting each other. Equal positions sort by id.
- **Moves:** a folder or saved link has a `parent` field (a folder id, or none for the top level). Moving an item changes `parent` and `position`, and the higher stamp decides.
- **Folder icons:** a folder's icon is one field, `icon` (`"emoji:📚"` or `"symbol:star.fill"`; null once removed), so the later edit wins it whole. Only a removal made on a Mac sends "no icon": removing one marks the folder in sidebar.json (`iconRemoved`) until the next sync has sent it. A folder that merely has no icon sends no `icon` field at all, so a Mac that has just updated betterlink (whose sidebar.json an older betterlink wrote without icons) can't stamp "no icon" over one another Mac set, and takes that icon on its next sync. A Mac on a betterlink from before folder icons leaves the field alone. Whether a folder is open is not synced; each Mac keeps its own.
- **Cycles:** two Macs might each move a folder into the other at once. After a merge, any folder whose parents form a loop goes to the top level, the one with the lowest id first, so every Mac makes the same choice. The Log says what moved.

## Deletes

- **A delete is a stamped field** (`deleted: true`), not a removal. So a delete wins over an older edit, and any later edit (which writes `deleted: false`) brings the item back. That covers editing an item on one Mac while deleting it on another, offline.
- **Deleting a folder** marks it and everything in it, each with the same stamp.
- **Orphans:** if one Mac adds a saved link to a folder that another Mac deletes, the link is kept and moves to the top level of that profile. The Log says where it went.
- **Tombstones** stay in the files, small (an id and a stamp). Removing them could bring an item back when a long-offline Mac returns, so v1 keeps them.

## Safety

Sync never deletes much without a person choosing it, and what it removes or replaces on a Mac can be put back there.

**The delete guard.** Before a push stamps `deleted: true`, it counts the synced items it would delete. It holds instead of writing when that is 5 or more at once, or 2 or more that are over half of this Mac's synced items, or anything at all from a settings folder that hasn't synced as this Mac before (a new folder that shares this Mac's sync preferences, as happened on 2026-11-25, when an empty test folder deleted 6 real items on every Mac). Global settings and config.ts aren't counted among this Mac's synced items. While held, the sync doesn't write this Mac's file and doesn't pull, so nothing changes anywhere. Sync settings names the items ("This Mac would delete 6 synced items at once: …") with two buttons:

- **Delete Them Everywhere**: the next push deletes exactly those items. Anything else it would delete asks again.
- **Keep Them**: the next push leaves them alone, and the pull that follows takes the shared ones back into this Mac's settings. After it, the folder counts as synced.

`betterlink sync paused` shows the hold and `betterlink sync resolve --choice delete|keep` answers it. Both work through this Mac's notes (below), so the CLI's answer reaches the running app's sync on its next round.

**Recently changed by sync.** Each pull notes what the merge takes away here, for what this Mac syncs: an item another Mac deleted (with all its fields), and a value another Mac's edit replaced (with the old value). A reorder alone isn't noted, and neither is this Mac's own edit. Sync settings lists the latest, each with **Restore**; `betterlink sync history` lists them all and `betterlink sync restore <id>` restores one. Restore stamps the old values (and `deleted: false` for a deleted item) as a new edit on this Mac, so they win the merge on every Mac. Restoring a deleted Sidebar Profile or folder also brings back what the same sync deleted inside it. The Mac that receives a restore notes it in its own list, so a restore can be undone the same way.

**This Mac's notes** are `sync-local.json` in its settings folder, written under a lock beside it by the sync and the CLI: the device this folder last synced as, the hold and its answer, restores asked for, and the history (newest first, the last 50, nothing older than 30 days). They never sync and never go in the sync folder.

## config.ts

config.ts is code and can't be merged field by field.

- It syncs as its own entity, part of the global settings switch: the newest version wins (its stamp is when it was last saved).
- The version it replaces is saved beside it as `config.ts.<Mac name>.<date>.bak`, and the Log links to it.

## Live

- Every Mac watches the sync folder (FSEvents; the existing PathWatcher, 0.3 s debounce) and its settings folder (0.5 s), and syncs 0.2 s after either changes. It also checks every 30 s, since a cloud app can replace a file without the folder noticing. Live, a change reached the other copy in about a second.
- A Mac rewrites its own file only when its state changed.
- The CLI, an editor and the app can write the settings files while a sync runs. A sync works from one reading of them and writes rules.json or sidebar.json only if, under that file's lock, it is still what the sync read; otherwise it starts over. It keeps the other Macs' changes to a file only once that file holds them. Editors take no lock, so config.ts changes places with its new version in one step; what was displaced is then compared, and either kept as a .bak or, when someone saved meanwhile, put back before the sync starts over. A linked config.ts stays a link, with its .bak beside the real file.
- A merge that changes anything saves rules.json and sidebar.json as usual. So the rest of betterlink, the CLI and the folder watch see ordinary file changes.

## Failure and edge cases

- **An unreadable or half-written device file** is skipped until it changes.
- **An unreadable rules.json, sidebar.json or config.ts on this Mac** (no permission, or a config.ts that isn't UTF-8 text) stops the sync with an error in Sync settings. Reading it as empty would delete everything in it on every Mac.
- **A Mac joining Macs that already sync:** its first sync stamps what it already has older than anything shared. Shared settings win every conflict, and what only this Mac has (a rule, a profile) is added for everyone. The first Mac in a folder stamps normally, so the next Mac to join can't override it.
- **A device file another user owns or can change** (or one in such a folder) is refused and named in the Log, with the check config.ts itself gets (FileSafety). Device files carry Link Rules and config.ts, which is code: anyone who can write into the sync folder as you can change what betterlink runs. Share the folder with no one.
- **A file from a newer format version** (`v2`) is ignored, and the Log asks to update betterlink.
- **A Mac with a clock far ahead** issues high stamps. The HLC keeps everyone after them, and edits still apply in the order they were made.
- **The sync folder disappears** (the provider quits, or the folder is renamed): sync pauses, says so in Sync settings, and resumes when the folder is back. Nothing local is removed.
- **Turning sync off on a Mac** leaves everything as it is locally and stops writing that Mac's file. The file stays, so other Macs keep everything it contributed.

## Tests

- **Property tests:** random edit sequences (add, rename, move, reorder, delete, undelete, config.ts saves) on 2–3 simulated Macs, with files delivered late, duplicated and out of order. Every Mac must end with identical state, and nothing may be lost except by a delete.
- **Scenario tests:**
  - the same field edited at once
  - a move against a delete
  - an add into a folder deleted elsewhere
  - the cycle case
  - a clock-skewed Mac
  - a half-written file
  - a config.ts conflict and its `.bak`
  - selective sync (an unsynced profile never leaves this Mac or changes there)
  - the delete guard: 5 at once and most of a few are held, fewer go through, a fresh settings folder deletes nothing shared, Delete proceeds only for what was held, Keep brings the shared items back
  - history and Restore: a delete and a replaced value are noted with their old values, the list is capped, a restore wins on both Macs, a restored folder brings back its links
- **Live:** two copies of betterlink on the Mac mini, each with its own settings folder and device id, pointed at one Dropbox folder. Edits on both at once must converge.

## Rules on another Mac

Link Rules, modifier rules and the fallback point at a browser profile by its folder in the browser ("Default", "Profile 1"), and the same Chrome profile can sit in a different folder on another Mac. So a synced rule also carries the profile's signed-in Google account and display name, from the browser's Local State. Each Mac finds the profile by account first, then by display name (Nick, 2026-11-24). A rule whose profile isn't on this Mac opens in the fallback (the same browser's Default profile when none is set), never in a profile that only shares the other Mac's folder name; the Log says how many such rules there are when that number changes (the Link Rules page's mark is not built yet). Only Chromium browsers keep profiles in Local State to match; rules for Safari, Firefox and its relatives, and for a Chromium browser whose Local State can't be read, apply as they are. A rule whose own folder here holds the same profile keeps that folder, so two profiles with one name never swap.

Each Mac remembers which of its own profiles it put in place for each synced rule (`applied` in its device file). While a rule still points there, the Mac sends the synced profile fields back unchanged, so two Macs with the profile in different folders never overwrite each other. Pointing the rule at another profile on any Mac is an edit and syncs as one. The fallback works the same way, and a synced fallback this Mac can't match leaves this Mac's own.
