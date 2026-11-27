#!/bin/bash
# usage: fs.sh <app> <label>: sidebar shown (left 280) on a Chrome for Testing window half the screen; then zoom (fill) and native full screen; window-server frames of browser and panels
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2
browser_for chrome; live_init "$A" chrome
bash "$D/rig.sh" "$A" "$CHURN?fs#0" >/dev/null; read P H C < "$RUN/pids"
set_ '{"shown":false,"side":"left","width":280}'
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"
st() { "$T/zo" | awk -v p="pid=$P" -v c="pid=$C" '{for(i=1;i<=NF;i++) if($i==p||$i==c) printf "%s %s %s %s %s | ", $i,$(i+2),$(i+3),$(i+4),$(i+5)}'; echo; }
mkdir -p "$OUT"
for mode in zoom fs; do
  "$T/setf" "$C" $((SX+400)) "$SY" $((SW-800)) "$SH"; sleep 1.2; front; sleep .5; hotkey; sleep 1.5
  echo "### $L $mode: shown: $(st)"
  ("$T/ft" 2500 "$P" "$C" > "$RUN/ft.txt" &); sleep .1
  if [ $mode = zoom ]; then "$T/axz" "$C" zoom >/dev/null; sleep 3; echo "### $L zoomed: $(st)"; "$T/axz" "$C" zoom >/dev/null; sleep 2; echo "### $L unzoomed: $(st)"
  else "$T/axz" "$C" fs-on >/dev/null; sleep 4; echo "### $L full screen: $(st)"; "$T/axz" "$C" fs-off >/dev/null; sleep 4; echo "### $L left full screen: $(st)"; fi
  cp "$RUN/ft.txt" "$OUT/ft-$L-$mode.txt" 2>/dev/null
  front; hotkey; sleep 1.5
done
save_trace "fs-$L-trace.log"
