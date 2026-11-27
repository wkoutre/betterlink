#!/bin/bash
# usage: fill.sh <app> <label>: sidebar shown (left 280) on a Chrome for Testing window; the window is then made to fill the visible screen (as Window > Fill or a tiling app does); frames over time
# Two starts: a window from 1/5 of the screen's width (3/5 wide; the original run on a 2056-wide screen used x=400 w=1256), and one already as wide as the screen.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2
browser_for chrome; live_init "$A" chrome
bash "$D/rig.sh" "$A" "$CHURN?fill#0" >/dev/null; read P H C < "$RUN/pids"
set_ '{"shown":false,"side":"left","width":280}'
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"
st() { "$T/zo" | awk -v p="pid=$P" -v c="pid=$C" '{for(i=1;i<=NF;i++) if($i==p||$i==c) printf "%s %s %s %s %s | ", $i,$(i+2),$(i+3),$(i+4),$(i+5)}'; echo; }
for start in "$((SW/5)) $((SW*3/5))" "0 $SW"; do set -- $start
  "$T/setf" "$C" $((SX+$1)) "$SY" "$2" "$SH"; sleep 1.2; front; sleep .5; hotkey; sleep 1.5
  echo "### $L from x=$1 w=$2 shown: $(st)"
  "$T/setf" "$C" "$SX" "$SY" "$SW" "$SH"; for t in 0.3 1 2 3; do sleep $t; echo "### $L   +$t s after fill: $(st)"; done
  front; hotkey; sleep 1.5; echo "### $L   hidden: $(st)"
done
save_trace "fill-$L-trace.log"
