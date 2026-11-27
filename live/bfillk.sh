#!/bin/bash
# usage: bfillk.sh <app> <label> <brave|chrome>: like bfill.sh but shown and hidden with the shortcut: a window filling the screen (and a left half), left then right; frames before show, after show, after hide
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2; K=$3
browser_for "$K"; live_init "$A" "$K"
"$B" agent sidebar.settings.set "{\"enabled\":true,\"shown\":false,\"takeOverTabs\":false,\"browsers\":[\"$NAME\"]}" | grep -o '"ok":[a-z]*'
start_app; sleep 4; unreg
P=$(app_pid); [ -n "$P" ] || die "the rig app did not start"; "$T/cl" "$P" >/dev/null 2>&1
launch_throwaway "$RUN/ble/p" fill 200,150 900,600
sleep 7; C=$(chrome_pid "$RUN/ble/p"); [ -n "$C" ] || die "the throwaway browser did not start"
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"; H2=$((SW/2))
pn() { "$T/zo" | awk -v p="pid=$P" '$3==p{printf "%s/%s ", $5, $7}'; }
echo "### $L $K screen $SX $SY $SW $SH x$sc"
for side in left right; do set_ "{\"side\":\"$side\"}"; sleep 1
 for t in "0 $SW" "0 $H2" "$H2 $H2"; do a_=($t); set_ '{"shown":false}'; sleep 1.2; front; "$T/setf" "$C" $((SX+a_[0])) "$SY" "${a_[1]}" "$SH"; sleep 1.5; a=$(fr); front; sleep .5; hotkey; sleep 2; b=$(fr); p=$(pn); front; sleep .3; hotkey; sleep 2; c=$(fr)
  ok=OK; [ "$a" = "$c" ] || ok=DIFF; echo "$ok $side | before $a | shown $b panel $p | hidden $c"; done; done
save_trace "bfillk-$L-$K-trace.log"
