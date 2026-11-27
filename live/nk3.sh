#!/bin/bash
# usage: nk3.sh <app> <label> <on|off>: Nick's show/hide (left 280) on a Chrome for Testing window filling the screen, with the browser's AXEnhancedUserInterface on or off;
# every window-server frame of the browser and the panels (ft), and a 60 fps ScreenCaptureKit recording of betterlink's own windows only (pv60, lines starting PV)
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2; M=$3
[ "$M" = on ] || [ "$M" = off ] || die "usage: nk3.sh <app> <label> <on|off>"
browser_for chrome; live_init "$A" chrome sr
bash "$D/rig.sh" "$A" "$CHURN?nk#0" >/dev/null; read P H C < "$RUN/pids"
set_ '{"shown":false,"side":"left","width":280}'
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"
"$T/setf" "$C" "$SX" "$SY" "$SW" "$SH"; sleep 1.5; "$T/enh" "$C" "$M" >/dev/null; echo "### $L enhanced=$("$T/enh" "$C") screen $SX,$SY ${SW}x$SH"
front; sleep 1
echo "-- show"; hotkey; sleep 2; for i in 1 2 3; do echo "-- hide $i"; ("$T/ft" 1500 "$P" "$C" &); ("$T/pv60" 1500 "$P" | sed "s/^/PV /" &); sleep 0.5; hotkey; sleep 2; echo "-- show $i"; hotkey; sleep 2; done
echo "enhanced after: $("$T/enh" "$C")"
save_trace "nk3-$L-$M-trace.log"
