#!/bin/bash
# usage: ed.sh <app> <label> <chrome|brave>: drags the sidebar's inner edge, both sides, and samples how far the edge trails the pointer
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2; K=${3:-chrome}
browser_for "$K"; live_init "$A" "$K"
if [ "$K" = chrome ]; then bash "$D/rig.sh" "$A" "$CHURN?1#0" >/dev/null; read P H C < "$RUN/pids"
else mkdir -p "$RUN/ble"
  "$B" agent sidebar.settings.set '{"enabled":true,"takeOverTabs":false,"browsers":["Brave"]}' >/dev/null
  launch_throwaway "$RUN/ble/brave" ed 300,200 1000,700
  sleep 8; C=$(chrome_pid "$RUN/ble/brave")
  start_app; sleep 5; unreg
  P=$(app_pid); "$T/cl" "$P" >/dev/null 2>&1
fi
[ -n "$P" ] && [ -n "$C" ] || die "the rig app or the throwaway browser did not start"
tr_() { grep "edge drag:" "$RUN/home/trace.log" 2>/dev/null | tail -${1:-1} | sed 's/^[^e]*edge drag/   trace: edge drag/' | cut -c1-260; }
fw() { "$T/ax" "$C" frames | sed 's/.*(//;s/[,)]//g;s/\.0//g' | head -1; }
echo "### $L $K"
for side in left right; do sg=1; [ $side = right ] && sg=-1
  set_ '{"shown":false}'; sleep 1; set_ "{\"side\":\"$side\",\"width\":280}"; sleep .5; front; "$T/setf" "$C" 400 150 1300 800; sleep 1; set_ '{"shown":true}'; sleep 2.5
  echo "## $side: window $(fw)"
  for t in "wider 80 1500" "narrower -120 1500" "fast-wider 100 300" "past-max 400 1200" "past-min -500 1200" "back 80 800"; do set -- $t; front; sleep .3
    echo " $1:"; "$T/edr" "$P" "$C" $side $(($2*sg)) $3 | grep -E "SUMMARY|no panel| up |refusing" | sed 's/^/   /'; tr_; sleep .8; done
  # at the browser's minimum: the window is made narrow, then the edge is asked for more
  set_ '{"shown":false}'; sleep 1.2; "$T/setf" "$C" 400 150 560 800; sleep 1; set_ '{"shown":true}'; sleep 2.5; echo " at-minimum (window before $(fw)):"; front; sleep .3
  "$T/edr" "$P" "$C" $side $((120*sg)) 1200 | grep -E "SUMMARY|no panel| up |refusing" | sed 's/^/   /'; tr_; echo "   window after $(fw)"
  # keyboard steps: two quick increments, then one more, then a decrement
  set_ '{"shown":false}'; sleep 1.2; "$T/setf" "$C" 400 150 1300 800; sleep 1; set_ '{"width":280}'; set_ '{"shown":true}'; sleep 2.5
  n0=$(grep -c "edge drag:" "$RUN/home/trace.log" 2>/dev/null); echo "   $("$T/nd" "$P" "Sidebar width" AXIncrement 2 40)"; sleep 1.2
  n1=$(grep -c "edge drag:" "$RUN/home/trace.log" 2>/dev/null); echo " two quick increments: $((n1-n0)) trace line(s)"; tr_ $((n1-n0>0?n1-n0:1)); echo " one decrement: $("$T/nd" "$P" "Sidebar width" AXDecrement 1)"; sleep 1.2; tr_
  echo " eighteen increments held past the limit, then one decrement: $("$T/nd" "$P" "Sidebar width" AXIncrement 18 40) / $("$T/nd" "$P" "Sidebar width" AXDecrement 1)"; sleep 1.2; tr_ 2
  echo " settings: $("$B" agent sidebar.settings.get | grep -o '"width":[0-9.]*')"
  w1=$(fw); set_ '{"shown":false}'; sleep 2; w2=$(fw); front; set_ '{"shown":true}'; sleep 2.5; echo " hide and show after the drags: shown $w1 | hidden $w2 | shown again $(fw)"
done
save_trace "ed-$L-$K-trace.log"
