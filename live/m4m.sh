#!/bin/bash
# usage: m4m.sh <app> <label>: app cost with four windows, another app (Finder) in front: quiet / one background tab changing / 56 tabs changing
# Output: one line per case, then betterlink's and the tab host's "<pid>: cpu X%  wakeups Y/s  memory Z MB" over 30 s each.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2
browser_for chrome; live_init "$A" chrome
CFT=$BROWSER
bash "$D/rig.sh" "$A" "$CHURN?w1#0" >/dev/null; read P H C < "$RUN/pids"
for i in 2 3 4; do "$CFT" --user-data-dir="$RUN/udd" --use-mock-keychain --password-store=basic --new-window "$CHURN?w$i#0" >/dev/null 2>&1; sleep 1.5; done
front; sleep 4
F=$(pgrep -x Finder | head -1); [ -n "$F" ] || die "Finder is not running"
"$T/ax" "$F" front >/dev/null; sleep 6
m() { "$T/mr" 30 "$P" "$H" 2>&1 | tail -3 | tr '\n' ' '; echo; }
echo "$L | windows $("$T/wn" "$C" list | wc -l | tr -d ' '), panels on screen $("$T/zo" | awk -v p="pid=$P" '$3==p' | wc -l | tr -d ' ')"
echo "$L | (a) four quiet windows, Finder in front: $(m)"
"$CFT" --user-data-dir="$RUN/udd" --use-mock-keychain --password-store=basic "$CHURN?bg#500" >/dev/null 2>&1; sleep 2; "$CFT" --user-data-dir="$RUN/udd" --use-mock-keychain --password-store=basic "$CHURN?fg#0" >/dev/null 2>&1; sleep 2; "$T/ax" "$F" front >/dev/null; sleep 5
echo "$L | (b) plus one background tab changing its title twice a second: $(m)"
urls=(); for i in $(seq 1 56); do urls+=("$CHURN?c$i#500"); done
"$CFT" --user-data-dir="$RUN/udd" --use-mock-keychain --password-store=basic --new-window "${urls[@]}" >/dev/null 2>&1; sleep 8; "$T/ax" "$F" front >/dev/null; sleep 5
echo "$L | (c) plus a window of 56 tabs changing twice a second, Finder in front: $(m)"
[ -n "${SAMPLE:-}" ] && sample "$P" 15 -file "$SAMPLE" >/dev/null 2>&1
save_trace "m4m-$L-trace.log"
