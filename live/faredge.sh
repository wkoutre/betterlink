#!/bin/bash
# usage: faredge.sh <app> <label> <left|right> <idle|heavy> <full|free> [N=20] [chrome|brave]
# N shows + N hides with the shortcut on one throwaway browser window (Chrome for Testing through rig.sh, or Brave with a
# throwaway profile), every window-server frame of the browser and betterlink traced by ftk, which sends the press itself
# (only while the throwaway browser is in front), and each hide recorded at 60 fps (pv60, betterlink's windows only).
# heavy: four more tabs of heavy.html (20 000 rows, 400 changed every frame). full: the window fills the screen's visible
# frame; free: 300 pt in from the left, 400 pt short of the right. Read the output with faredge-an.py (far edge per frame).
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2; SIDE=$3; LOAD=$4; WIN=$5; N=${6:-20}; KIND=${7:-chrome}
OUTD=${LIVE_OUT:-$D/out/faredge}; mkdir -p "$OUTD"
browser_for "$KIND"; live_init "$A" "$KIND" sr
mkdir -p "$W"; cp "$D/heavy.html" "$W/heavy.html"   # beside $RUN, which rig.sh starts afresh
EXTRA=; [ "$LOAD" = heavy ] && EXTRA="file://$W/heavy.html file://$W/heavy.html file://$W/heavy.html file://$W/heavy.html"
if [ "$KIND" = chrome ]; then
  bash "$D/rig.sh" "$A" $EXTRA "$CHURN?fe#0" >/dev/null; read P TH C < "$RUN/pids"
else
  "$B" agent sidebar.settings.set '{"enabled":true,"shown":false,"takeOverTabs":false,"browsers":["Brave"]}' | grep -o '"ok":[a-z]*'
  start_app; sleep 4; unreg
  P=$(app_pid); [ -n "$P" ] || die "the rig app did not start"; "$T/cl" "$P" >/dev/null 2>&1
  mkdir -p "$RUN/ble/p"
  nohup "$BROWSER" --user-data-dir="$RUN/ble/p" --use-mock-keychain --password-store=basic --no-first-run --no-default-browser-check --disable-background-timer-throttling --disable-renderer-backgrounding --window-position=200,150 --window-size=1100,800 "data:text/html,<title>fe</title>fe" $EXTRA >/dev/null 2>&1 &
  sleep 8; C=$(chrome_pid "$RUN/ble/p"); [ -n "$C" ] || die "the throwaway browser did not start"
fi
set_ "{\"shown\":false,\"side\":\"$SIDE\",\"width\":280}"
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"
if [ "$WIN" = full ]; then X=$SX; WW=$SW; else X=$((SX+300)); WW=$((SW-700)); fi
"$T/setf" "$C" "$X" "$SY" "$WW" "$SH"; sleep 1.5
OUTF=$OUTD/$L-$KIND-$SIDE-$LOAD-$WIN.txt
echo "### $L $KIND side=$SIDE load=$LOAD win=$WIN enhanced=$("$T/enh" "$C") screen $SX,$SY ${SW}x$SH window $X,$SY ${WW}x$SH" > "$OUTF"
front; sleep 1
for i in $(seq 1 "$N"); do
  front; sleep 0.3
  echo "-- show $i" >> "$OUTF"; "$T/ftk" 1400 300 "$C" "$P" "$C" >> "$OUTF"; sleep 0.6
  front; sleep 0.3
  echo "-- hide $i" >> "$OUTF"; ("$T/pv60" 1700 "$P" | sed "s/^/PV /" > "$RUN/pv.txt" &); "$T/ftk" 1400 300 "$C" "$P" "$C" >> "$OUTF"; sleep 0.5; cat "$RUN/pv.txt" >> "$OUTF"; sleep 0.3
done
echo "enhanced after: $("$T/enh" "$C")" >> "$OUTF"
cp "$RUN/home/trace.log" "${OUTF%.txt}-trace.log" 2>/dev/null
echo "wrote $OUTF"
