#!/bin/bash
# usage: run-all.sh <ref> [checkout]   (env ONLY=<regex> runs only the steps whose names match, e.g. ONLY='^05-(geo3|ed)')
# Builds (build.sh <ref> [checkout]) and then runs every live test, one after the other, saving each output under
# live/out/<ref>-<date>/NN-name.txt (traces and captures land beside them) and a SUMMARY.txt.
# Do not use the Mac while it runs: the tests move windows and press the shortcut. STOP (exit 2) means a permission
# or another running app needs a person: read the message, ask Nick, and never click a macOS prompt.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
REF=${1:?usage: run-all.sh <ref> [checkout]}; CHECKOUT=${2:-$HOME/Projects/betterlink}
bash "$D/build.sh" "$REF" "$CHECKOUT" || exit $?
A=$(cat "$W/app-path"); SHA=$(cut -d' ' -f2 "$W/app-ref")
need_perms ax sr
o=$(others "/Contents/MacOS/Betterlink"); [ -z "$o" ] || { echo "STOP: betterlink is already running outside the rig (two copies would fight over the shortcut and the windows). Ask Nick to quit it. Seen: $(echo "$o" | head -2 | cut -c1-160)"; exit 2; }
o=$(others "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"); [ -z "$o" ] || { echo "STOP: another Chrome for Testing is running (for example a Playwright browser); the sidebar would attach to its windows. Ask Nick to close it. Seen: $(echo "$o" | head -2 | cut -c1-160)"; exit 2; }
LABEL=$(printf '%s' "$REF" | tr -c 'A-Za-z0-9._-' '-')
OUT=$D/out/$LABEL-$(date +%Y-%m-%d); n=1; while [ -e "$OUT" ]; do n=$((n+1)); OUT=$D/out/$LABEL-$(date +%Y-%m-%d)-$n; done
mkdir -p "$OUT"; export LIVE_OUT=$OUT
{ echo "ref $REF = $SHA"; echo "date $(date)"; echo "macOS $(sw_vers -productVersion) build $(sw_vers -buildVersion) $(uname -m)"
  echo "screen (x y w h scale): $("$T/scr" | head -1)"
  echo "Chrome for Testing: $("$(cft_bin)" --version 2>/dev/null)"
  echo "Brave: $(defaults read "/Applications/Brave Browser.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo not installed)"
  echo "app $A"; } > "$OUT/info.txt"
cat "$OUT/info.txt"

: > "$OUT/SUMMARY.txt"
step() {   # step <name> <script> [args...]
  local name=$1 script=$2; shift 2
  if [ -n "${ONLY:-}" ] && ! echo "$name" | grep -Eq "$ONLY"; then return 0; fi
  echo "=== $name"
  bash "$D/$script" "$@" > "$OUT/$name.txt" 2>&1; local rc=$? note=
  case $rc in
    0) note=ok;;
    3) note="SKIPPED: $(grep -m1 '^SKIPPED' "$OUT/$name.txt" | cut -c1-200)";;
    2) note="STOP: $(grep -m1 '^STOP' "$OUT/$name.txt" | cut -c1-300)";;
    *) note="FAILED rc=$rc: $(tail -1 "$OUT/$name.txt" | cut -c1-200)";;
  esac
  local diffs flick hks; diffs=$(grep -c '^DIFF' "$OUT/$name.txt"); flick=$(grep -c 'FLICKER' "$OUT/$name.txt"); hks=$(grep -c 'SKIPPED hotkey' "$OUT/$name.txt")
  echo "$name: $note  [DIFF lines $diffs, FLICKER lines $flick, skipped hotkeys $hks]" | tee -a "$OUT/SUMMARY.txt"
  if [ $rc = 2 ]; then echo "Stopped at $name. Nothing else was run. Ask Nick; do not click any macOS prompt."; exit 2; fi
}
step 01-probe          probe.sh "$LABEL"
step 02-nk3-on         nk3.sh "$A" "$LABEL" on
step 02-nk3-off        nk3.sh "$A" "$LABEL" off
step 03-flicker        flicker.sh "$A" "$LABEL"
step 04-fill           fill.sh "$A" "$LABEL"
step 04-fs             fs.sh "$A" "$LABEL"
step 05-bfill-chrome   bfill.sh "$A" "$LABEL" chrome
step 05-bfill-brave    bfill.sh "$A" "$LABEL" brave
step 05-bfillk-chrome  bfillk.sh "$A" "$LABEL" chrome
step 05-bfillk-brave   bfillk.sh "$A" "$LABEL" brave
step 05-bnar-brave     bnar.sh "$A" "$LABEL"
step 05-bopen-chrome   bopen.sh "$A" "$LABEL" chrome
step 05-bopen-brave    bopen.sh "$A" "$LABEL" brave
step 05-geo3           geo3.sh "$A" "$LABEL"
step 05-ed-chrome      ed.sh "$A" "$LABEL" chrome
step 05-ed-brave       ed.sh "$A" "$LABEL" brave
step 05-atmin3-chrome  atmin3.sh "$A" "$LABEL" chrome
step 05-atmin3-brave   atmin3.sh "$A" "$LABEL" brave
step 05-tlag           tlag.sh "$A" "$LABEL"
step 06-m4m            m4m.sh "$A" "$LABEL"
echo "Done. Outputs: $OUT"
