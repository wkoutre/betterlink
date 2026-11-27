#!/bin/bash
# usage: bopen.sh <app> <label> <brave|chrome>: rule 3/4 live: show (shortcut), then the browser is resized or moved while open, then hide; the browser must take the pair's frame (sidebar + browser) as it was at hide time
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2; K=$3
browser_for "$K"; live_init "$A" "$K"
"$B" agent sidebar.settings.set "{\"enabled\":true,\"shown\":false,\"width\":280,\"takeOverTabs\":true,\"browsers\":[\"$NAME\"]}" | grep -o '"ok":[a-z]*'
start_app; sleep 4; unreg
P=$(app_pid); [ -n "$P" ] || die "the rig app did not start"; "$T/cl" "$P" >/dev/null 2>&1
launch_throwaway "$RUN/ble/p" open 200,150 900,600
sleep 7; C=$(chrome_pid "$RUN/ble/p"); [ -n "$C" ] || die "the throwaway browser did not start"
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"
# the panel's visible frame (the window list's width includes a shadow margin on the far side)
pnx() { "$T/zo" | awk -v p="pid=$P" '{for(i=1;i<=NF;i++) if($i==p){print $(i+1), $(i+2), $(i+4); exit}}' | tr -d '#xw='; }
echo "### $L $K"
for side in left right; do set_ "{\"side\":\"$side\"}"; sleep 1
 for act in "narrow 200" "widen-by-shrinking-sidebar-room 0" "move 120"; do set -- $act
  front; "$T/setf" "$C" $((SX+300)) "$SY" 1200 "$SH"; sleep 1.5; a=$(fr); front; sleep .4; hotkey; sleep 2.2; b=($(fr))
  case $1 in
   narrow) if [ $side = left ]; then "$T/setf" "$C" "${b[0]}" "${b[1]}" $((b[2]-$2)) "${b[3]}"; else "$T/setf" "$C" $((b[0]+$2)) "${b[1]}" $((b[2]-$2)) "${b[3]}"; fi;;
   move) "$T/setf" "$C" $((b[0]-$2)) "${b[1]}" "${b[2]}" "${b[3]}";;
   *) : ;;
  esac
  sleep 2; w=($(fr)); p=($(pnx)); pw=280
  if [ $side = left ]; then exl=$(( w[0] - pw )); exr=$(( w[0] + w[2] )); else exl=${w[0]}; exr=$(( w[0] + w[2] + pw )); fi
  front; sleep .3; hotkey; sleep 2.2; c=($(fr))
  ok=OK; [ "${c[0]}" = "$exl" ] && [ $(( c[0] + c[2] )) = "$exr" ] || ok=DIFF
  echo "$ok $side $1 | before $a | shown ${b[*]} | while open ${w[*]} panel x=${p[1]} | hidden ${c[*]} | expected x $exl..$exr"
 done; done
save_trace "bopen-$L-$K-trace.log"
