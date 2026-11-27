#!/bin/bash
# usage: tlag.sh <app> <label>: one window, its tab's title counting up twice a second; how far the sidebar's title lags the browser's, Finder in front then the browser in front
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2
browser_for chrome; live_init "$A" chrome
bash "$D/rig.sh" "$A" "$CHURN?lag#500" >/dev/null; read P H C < "$RUN/pids"; sleep 3
F=$(pgrep -x Finder | head -1); [ -n "$F" ] || die "Finder is not running"
br() { "$T/ui" dump "$C" 2>/dev/null | grep -o 'tab [0-9]*' | head -1 | awk '{print $2}'; }
sb() { "$T/ui" dump "$P" 2>/dev/null | grep -o 'tab [0-9]*' | head -1 | awk '{print $2}'; }
run() { for i in $(seq 1 "$2"); do b=$(br); s=$(sb); echo "$1 browser $b sidebar $s lag $(( ${b:-0} - ${s:-0} ))"; sleep 0.25; done; }
"$T/ax" "$F" front >/dev/null; sleep 3; run finder 24
front; sleep 0.3; run browser 12
save_trace "tlag-$L-trace.log"
