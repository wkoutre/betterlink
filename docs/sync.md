# Sync (design)

Status: design for review. Nothing is built yet.

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
  config/<device-id>.ts         that Mac's latest config.ts, when Global settings sync
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
- **The same field resolves by stamp.** Both Macs rename one folder at once: the later edit wins, on every Mac. If the losing edit was this Mac's own, the Log says so, with the losing value and a Restore button.

## Lists and moves

- **Order:** each favorite, folder and saved link has a `position`, a fractional index (a string that sorts between its neighbours). Inserting between two items creates a new key, so two Macs reordering one list both keep their changes instead of overwriting each other. Equal positions sort by id.
- **Moves:** a folder or saved link has a `parent` field (a folder id, or none for the top level). Moving an item changes `parent` and `position`, and the higher stamp decides.
- **Cycles:** two Macs might each move a folder into the other at once. After a merge, any folder whose parents form a loop goes to the top level, the one with the lowest id first, so every Mac makes the same choice. The Log says what moved.

## Deletes

- **A delete is a stamped field** (`deleted: true`), not a removal. So a delete wins over an older edit, and any later edit (which writes `deleted: false`) brings the item back. That covers editing an item on one Mac while deleting it on another, offline.
- **Deleting a folder** marks it and everything in it, each with the same stamp.
- **Orphans:** if one Mac adds a saved link to a folder that another Mac deletes, the link is kept and moves to the top level of that profile. The Log says where it went.
- **Tombstones** stay in the files, small (an id and a stamp). Removing them could bring an item back when a long-offline Mac returns, so v1 keeps them.

## config.ts

config.ts is code and can't be merged field by field.

- The newest version wins (its stamp is when it was last saved).
- The version it replaces is saved beside it as `config.ts.<Mac name>.<date>.bak`, and the Log links to it.

## Live

- Every Mac watches the sync folder (FSEvents; the existing PathWatcher) and merges within about a second of a file landing.
- A Mac writes its own file at most once a second, after edits stop for 0.5 s.
- A merge that changes anything saves rules.json and sidebar.json as usual. So the rest of betterlink, the CLI and the folder watch see ordinary file changes.

## Failure and edge cases

- **An unreadable or half-written device file** is skipped until it changes.
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
- **Live:** two copies of betterlink on the Mac mini, each with its own settings folder and device id, pointed at one Dropbox folder. Edits on both at once must converge.

## Open question for Nick

Link Rules and the fallback point at a browser profile by its folder name in the browser ("Default", "Profile 1"). The same Chrome profile can have a different folder name on another Mac. Proposal: a synced rule also carries the profile's display name ("Work"). Each Mac matches by display name. A rule whose profile isn't on this Mac opens in the fallback, and the Rules page marks it. (A Sidebar Profile's browser-profile link doesn't sync at all, so it needs no matching.)
