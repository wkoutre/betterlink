#!/bin/bash
# usage: warmup.sh [app]   (app defaults to the one build.sh built: $TMPDIR/betterlink-live/app-path)
# Triggers every macOS permission prompt once, in order, so a person (Nick) can approve them all now. It prints what it is about to
# trigger and waits for Enter before each step. NOBODY CLICKS A PROMPT BUT THE PERSON: if a prompt appears, stop and ask Nick.
# Run build.sh first (it compiles the tools and builds the rig app). At the end it prints pass/fail per permission, quits everything it
# opened and removes its temporary folders. Screen captures are of its own throwaway browser window only (screencapture -l).
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
[ -x "$T/trust" ] || die "run build.sh first (the tools are not compiled)"
APP=${1:-$(cat "$W/app-path" 2>/dev/null)}
trap cleanup EXIT; trap 'exit 130' INT TERM
mkdir -p "$W"; kill_ours; rm -rf "$RUN"; mkdir -p "$RUN/home" "$SOCK" "$OUT"
res() { echo "$1: $2" >> "$RUN/results"; }
pause() { echo; echo "---- $1"; echo "     $2"; read -r -p "     Press Enter to trigger it (Ctrl-C to stop) " _; }
CFT=$(cft_bin)

pause "1/5 Accessibility" "macOS will ask to let this terminal app control the computer. Approve it (the person at the Mac does this)."
"$T/trust" >/dev/null; read -r -p "     Approved it? Press Enter " _
"$T/perm" | grep -q 'accessibility=true' && res "Accessibility (terminal)" PASS || res "Accessibility (terminal)" FAIL

pause "2/5 Screen Recording" "A throwaway Chrome for Testing window opens and only ITS window is captured (screencapture -l). macOS will ask for Screen Recording."
if [ -z "$CFT" ]; then echo "     Chrome for Testing is not installed: run build.sh for the command."; res "Screen Recording" SKIPPED
else
  BROWSER=$CFT; launch_throwaway "$RUN/w2" warmup 200,150 700,500; sleep 6
  C=$(chrome_pid "$RUN/w2"); n=$("$T/zo" | awk -v p="pid=$C" '{for(i=1;i<=NF;i++) if($i==p) print substr($(i+1),2)}' | head -1)
  [ -n "$n" ] && screencapture -x -o -l"$n" "$RUN/warmup.png"; read -r -p "     Approved it (re-run the capture if macOS asked you to restart the terminal)? Press Enter " _
  [ -n "$n" ] && screencapture -x -o -l"$n" "$RUN/warmup.png"
  "$T/perm" | grep -q 'screenrecording=true' && res "Screen Recording (terminal)" PASS || res "Screen Recording (terminal)" FAIL
  pkill -f "user-data-dir=$(rx "$RUN")/w2" 2>/dev/null
fi

pause "3/5 Automation" "macOS will ask to let this terminal control System Events, then TextEdit (the probe opens its own document, moves its window, closes it)."
osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' >/dev/null 2>&1 && res "Automation: System Events" PASS || res "Automation: System Events" FAIL
BETTERLINK_PROBE_CSV="$RUN/probe.csv" "$T/probe" >/dev/null 2>&1 && res "Automation: TextEdit (probe)" PASS || res "Automation: TextEdit (probe)" FAIL

pause "4/5 Browsers" "Chrome for Testing, then Brave, each opens once with a throwaway profile (--use-mock-keychain --password-store=basic, so no Safe Storage keychain prompt). Allow anything macOS asks."
for k in chrome brave; do
  ( browser_for "$k" ) >/dev/null 2>&1 || { echo "     $k: not installed, skipped"; res "Browser $k opens" SKIPPED; continue; }
  browser_for "$k"; launch_throwaway "$RUN/w4$k" warmup 200,150 700,500; sleep 6
  [ -n "$(chrome_pid "$RUN/w4$k")" ] && res "Browser $k opens" PASS || res "Browser $k opens" FAIL
  read -r -p "     $k is open. Press Enter to close it " _; pkill -f "user-data-dir=$(rx "$RUN")/w4$k" 2>/dev/null
done

pause "5/5 The test betterlink build" "It launches once from the rig clone ($APP) with a temporary BETTERLINK_HOME and BETTERLINK_TOUR=off; macOS will ask for its Accessibility."
if [ -z "$APP" ] || [ ! -x "$APP/Contents/MacOS/Betterlink" ]; then echo "     no built app: run build.sh first."; res "betterlink (rig build) launches" SKIPPED
else
  use_app "$APP"; start_app; sleep 5; unreg
  P=$(app_pid); [ -n "$P" ] && res "betterlink (rig build) launches" PASS || res "betterlink (rig build) launches" FAIL
  read -r -p "     Approve its Accessibility prompt (System Settings may need the toggle), then press Enter " _
  "$B" agent sidebar.settings.get >/dev/null 2>&1 && res "betterlink agent answers" PASS || res "betterlink agent answers" FAIL
fi

echo; echo "==== results (read-only checks)"; cat "$RUN/results"
echo "Anything FAIL: ask Nick; nobody but a person clicks a macOS prompt."
