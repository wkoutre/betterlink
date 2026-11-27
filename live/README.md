# betterlink sidebar live tests

Reruns, on another Mac (macOS 27), the live sidebar tests run on the Mac mini. This branch (`nickkoutrelakos/live-bundle-motion`) is never merged and no PR is opened.

## The rules for the session that runs this

1. **If any macOS permission prompt appears, STOP and ask Nick. Never click it, never type a password.** Scripts that need a permission check first without prompting (`bin/perm`) and exit `STOP:` (code 2) when it is missing.
2. Do not use the Mac while a test runs: tests move windows and press betterlink's shortcut.
3. Run `warmup.sh` first, with Nick at the Mac, so every prompt is approved once.

## Order

```
cd ~/Projects/betterlink && git fetch origin && git checkout nickkoutrelakos/live-bundle-motion   # or any checkout of this branch
cd live
bash build.sh origin/main          # tools into bin/, app into $TMPDIR/betterlink-live/rig; read-only on your checkout
bash warmup.sh                     # every permission prompt once, Enter between steps; Nick approves
bash run-all.sh <ref>              # builds, then runs everything; outputs in out/<ref>-<date>/
```

Needs: Xcode Command Line Tools (`swiftc`), `git`, and what `make build` itself uses (bun and network for `make fetch`/`bun install`; python3). `make build` downloads its own dependencies; only Chrome for Testing is never downloaded by these scripts: if it is missing `build.sh` prints `npx playwright install chromium` and stops (exit 4).

`build.sh [ref] [checkout]`: ref is looked up as `origin/<ref>`, then `checkout/<ref>` (a local branch of your checkout), then as given (commit id or tag); default `origin/main`; checkout defaults to `~/Projects/betterlink`. The build happens in a separate clone at `$TMPDIR/betterlink-live/rig` (detached at the ref, `rig2.patch` applied, `make build`); your checkout is only read.

If `make build` fails on the Swift toolchain (stale Command Line Tools), the other Mac's session got past it by building with `SWIFTPM_CUSTOM_LIBS_DIR` set (known workaround, not the default; I could not verify it): `SWIFTPM_CUSTOM_LIBS_DIR=<dir> bash build.sh <ref>`; the variable is passed through to `make`.

## Chrome for Testing as a sidebar browser (what makes it work)

- `rig2.patch` adds one `Browser` line (`Google Chrome for Testing`, bundle id `com.google.chrome.for.testing`, Chromium family) to `Sources/BetterlinkCore/Profiles.swift` in the test build only. Its `dataFolder` is a path relative to `~/Library/Application Support` (betterlink joins them), and `..` steps climb out of it. On Nick's Mac it was `../../../../tmp/blr/udd`, which for a user at `/Users/<name>` resolves to `/tmp/blr/udd`. Here `build.sh` computes the equivalent for this bundle's own profile folder, `$TMPDIR/betterlink-live/run/udd`, substituting it for `@UDD_REL@` in `rig2.patch`, and checks that it resolves (`dataFolder check:` line) or stops.
- `rig.sh` launches Chrome for Testing with `--user-data-dir=$TMPDIR/betterlink-live/run/udd` (the folder above), `--use-mock-keychain --password-store=basic` (no Safe Storage keychain prompt), `--load-extension=<rig clone>/browser-extension`, and writes the native-messaging manifest into that profile.
- The sidebar's browser list is set under a temporary `BETTERLINK_HOME`, only to the browser under test, e.g. `Betterlink agent sidebar.settings.set '{"enabled":true,"browsers":["Google Chrome for Testing"],...}'`. Nick's Mac also used `["Google Chrome for Testing","Brave"]` in some runs; these scripts never list a browser they did not start, because the sidebar attaches by bundle id to every window of a listed browser, your own included.
- The shortcut is betterlink's default, **control+option+S** (key code 1; the first brief said A, but `Shortcut.swift` and the original `hk` use S). If this Mac's betterlink preferences hold a custom `sidebar.shortcut`, the scripts warn and the shortcut steps will not toggle.
- The rig app is ad-hoc or Developer-ID signed by `make build`; macOS may ask for Accessibility for it again after each rebuild (warmup step 5). STOP and ask Nick.

## Safety (all enforced in the scripts)

- Throwaway profiles only (`--user-data-dir` under `$TMPDIR/betterlink-live/run`); Brave only at `/Applications/Brave Browser.app` with such a folder. Dia and your own browsers are never touched.
- `BETTERLINK_HOME` is a temp folder and `BETTERLINK_TOUR=off`. The betterlink preference domains are never written (the preflight only reads `sidebar.shortcut`).
- `pkill`/`pgrep` patterns match only `user-data-dir=$TMPDIR/betterlink-live/run/` and the rig's own app path; scripts refuse an app outside the rig folder.
- Preflight: a running betterlink outside the rig, another Chrome for Testing (for example a Playwright browser) or your own Brave makes the affected script stop (`STOP`/`SKIPPED` with the reason). It never quits them for you.
- The shortcut (`hk`) is only sent when the frontmost app is the throwaway browser (`fp` check in the script, `hk` refuses again itself); otherwise the step prints `SKIPPED hotkey` and `run-all` counts them.
- Mouse events (`edr`) are only pressed when the window under the pointer is betterlink's or the throwaway browser's. `ax` and `ui` lost their click/key/type subcommands. `scroll` (unused) needs the pids it may scroll.
- Screen captures: `pv60` records only betterlink's windows (ScreenCaptureKit window filters); `atmin3` and `warmup` use `screencapture -l <window number>` of betterlink's and the throwaway browser's windows. Never the whole screen.
- Every script removes its temp folders and processes on exit (`cleanup.sh` does it by hand). The tab-title page is a `file://` page, not a local web server.

## Permissions

The terminal app needs **Accessibility** and **Screen Recording**; `warmup.sh` also triggers Automation (System Events, TextEdit for the probe), browser first-runs and the rig app's own Accessibility. STOP and ask Nick for each prompt.

## What each script checks, and the good result on Nick's Mac

Reference outputs: `/Volumes/Storage/Projects/betterlink-captures/live/` on the Mini (not in this branch).

| script (run-all step) | checks | read it as |
|---|---|---|
| `probe.sh` (01) | `probe --read` lists each app's AXEnhancedUserInterface; `probe --pid` moves and resizes one throwaway window five ways with it on and off | "UI on" animates (~25 frames, ~250 ms), "UI off" jumps (1-2 frames). Far edge moved up to 280 pt in single moves; 16 pt in the 18-step slide with UI off. macOS 26.5: matches. Report what 27 does differently. Frames in `probe-<label>.csv` |
| `nk3.sh` on/off (02) | show/hide with the shortcut on a screen-filling window, browser AXEnhancedUserInterface on/off; `ft` lists every window-server frame, `PV` lines are the 60 fps pixel recording | on: panel slides out, browser grows in steps over ~0.5 s, **far edge never moves**. off: single jumps. After the hide the panel's `visible cols` goes to 0 and stays there |
| `flicker.sh` (03) | five hides recorded at 60 fps | every cycle `OK`: **no panel pixels after a hide**. `FLICKER` = pixels came back (the `main-off` reference shows 312 cols again at 743 ms) |
| `fill.sh` (04) | window made to fill the screen while the sidebar is shown | **sidebar never off screen after fill**, window ends at the screen's full frame, hidden frame equals the start. The reference `fill-main.txt` is main before the fix (panel at x=-280); a good build shows the panel on screen |
| `fs.sh` (04) | zoom button and native full screen with the sidebar shown | panel leaves for full screen and comes back at the same place; only the window frames matter |
| `bfill.sh`, `bfillk.sh` (05) | show then hide (settings / shortcut), screen-filling and half windows, both sides | every line `OK`: hidden frame equals the frame before; shown frame = window minus the sidebar width |
| `bnar.sh` (05) | Brave against the right edge at 1028 to 600 pt wide | `OK`; `PAST THE RIGHT EDGE` only where Brave's own minimum width (615 pt on the Mini) forces it |
| `bopen.sh` (05) | window resized or moved while shown, then hidden | every line `OK`: the browser takes the pair's frame as it was at hide time (hidden x..x+w equals `expected`) |
| `geo3.sh` (05) | six screen positions, move while shown, width change while shown, rapid toggles, both sides | all lines `OK` (16 of 16 on the Mini) |
| `ed.sh` (05) | drags the sidebar's inner edge; keyboard width steps | `SUMMARY` lines: the window's edge trails the pointer by a few pt while dragging and 0 once held; **far edge moved 0.0**; panel at most a few pt off the window's edge; the width stops at the limits |
| `atmin3.sh` (05) | browser at its minimum width, shortcut pressed, frame and panel over 4 s, captures in `out/` | the frame settles within ~1 s and the panel is beside or over it as the trace says; compare the PNGs by eye |
| `tlag.sh` (05) | the sidebar's tab-title counter against the browser's | `lag` 0 to 1 with the browser in front; with Finder in front a few ticks of lag appear and shrink (reference: up to 4) |
| `m4m.sh` (06) | CPU/wakeups/memory of betterlink and its tab host, four windows, Finder in front | (a) 0.00% / 0.0 wakeups; (b) about 0.7% / 3.3; (c) about 3.4% / 2.6 (PR 79 numbers, 30 s each) |

`run-all.sh` writes `SUMMARY.txt` with one line per step (`ok`, `SKIPPED: reason`, `FAILED rc=N`) and counts of `DIFF`, `FLICKER` and skipped hotkeys. A `DIFF` is a failed same-as-before comparison. Send Nick the whole `out/<ref>-<date>/` folder (it is git-ignored).

Each step runs alone: `bash nk3.sh <app> <label> on`, `bash bfill.sh <app> <label> chrome`, and so on (`<app>` is `$TMPDIR/betterlink-live/app-path`'s content; each script's header gives its usage). `ONLY='^05-(geo3|ed)' bash run-all.sh <ref>` runs a subset.

## Files

`build.sh`, `warmup.sh`, `run-all.sh`, `lib.sh` (shared), `rig.sh`/`rigm.sh`, `cleanup.sh`, the test scripts above, `rig2.patch`, `src/*.swift` (compiled into `bin/` with `swiftc` only: `ax setf scr zo hk cl wn ui enh ft pv60 axz scroll w edr nd probe` plus `mr fp perm tm trust` written for this bundle).
