#!/bin/bash
# usage: atmin3.sh <app> <label> <chrome|brave>: Nick's settings (left, 280, takeover on) for the throwaway browser only; the browser at its minimum width, the shortcut pressed, the window frame and the panel sampled over 4 s, with window captures
# Captures are of the throwaway browser's and betterlink's own windows only (screencapture -l <window number>), into $OUT.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2; K=${3:-chrome}
browser_for "$K"; live_init "$A" "$K" sr
mkdir -p "$OUT"
"$B" agent sidebar.settings.set "{\"enabled\":true,\"shown\":false,\"side\":\"left\",\"width\":280,\"takeOverTabs\":true,\"browsers\":[\"$NAME\"]}" | grep -o '"ok":[a-z]*'
start_app; sleep 4; unreg
P=$(app_pid); [ -n "$P" ] || die "the rig app did not start"; "$T/cl" "$P" >/dev/null 2>&1
launch_throwaway "$RUN/ble/p" atmin 200,150 900,600
sleep 7; C=$(chrome_pid "$RUN/ble/p"); [ -n "$C" ] || die "the throwaway browser did not start"
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"
pn() { "$T/zo" | awk -v p="pid=$P" '{for(i=1;i<=NF;i++) if($i==p) printf "%s/%s ", $(i+2), $(i+4)}'; }
"$T/setf" "$C" 300 "$SY" 300 700; sleep 1.2; MIN=$(fr | awk '{print $3}'); echo "### $K minimum width $MIN"
for cs in "edge $MIN" "free $MIN"; do set -- $cs
 if [ "$1" = edge ] || [ "$1" = seed ]; then "$T/setf" "$C" $((SX+SW-$2)) "$SY" "$2" "$SH"; else "$T/setf" "$C" 600 $((SY+100)) "$2" 700; fi
 sleep 1.5; echo "### $cs before $(fr)"; front; sleep .4; T0=$("$T/tm" now); hotkey
 for t in 0.4 1.0 1.6 2.2 2.8 3.4 4.2; do "$T/tm" until "$T0" "$t"; echo "  t=$t frame $(fr) panel $(pn)"
  if [ "$t" = 0.4 ] || [ "$t" = 1.6 ]; then
   for n in $("$T/zo" | awk -v p="pid=$C" '{for(i=1;i<=NF;i++) if($i==p) print substr($(i+1),2)}' | head -1); do screencapture -x -o -l"$n" "$OUT/atmin-$L-$K-$1-$t-browser.png"; done
   for n in $("$T/zo" | awk -v p="pid=$P" '{for(i=1;i<=NF;i++) if($i==p) print substr($(i+1),2)}'); do screencapture -x -o -l"$n" "$OUT/atmin-$L-$K-$1-$t-panel-$n.png"; done
  fi; done
 echo "  press at $T0"; sleep 2; done
save_trace "atmin-$L-$K-trace.log"
