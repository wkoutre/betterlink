#!/bin/bash
# usage: flicker.sh <app> <label> [cycles=5]: the flicker recorder. Chrome for Testing window filling the screen, sidebar shown (left 280); then <cycles> times:
# the shortcut hides it while pv60 records betterlink's own windows at 60 fps (ScreenCaptureKit, only those windows) and ft logs every window-server frame; the shortcut shows it again.
# Verdict per cycle: OK when the panel window has no visible pixel after its last pixel went; FLICKER when pixels come back after that.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2; N=${3:-5}
browser_for chrome; live_init "$A" chrome sr
bash "$D/rig.sh" "$A" "$CHURN?flicker#0" >/dev/null; read P H C < "$RUN/pids"
set_ '{"shown":false,"side":"left","width":280}'
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"
"$T/setf" "$C" "$SX" "$SY" "$SW" "$SH"; sleep 1.5; front; sleep 1
echo "### $L flicker recorder, $N hides, screen $SX,$SY ${SW}x$SH"
hotkey; sleep 2
mkdir -p "$OUT"
for i in $(seq 1 "$N"); do
  PV=$RUN/pv-$i.txt; FT=$RUN/ft-$i.txt
  ("$T/ft" 1500 "$P" "$C" > "$FT" &); ("$T/pv60" 1500 "$P" > "$PV" &); sleep 0.5; hotkey; sleep 2
  cp "$PV" "$OUT/flicker-$L-pv-$i.txt" 2>/dev/null; cp "$FT" "$OUT/flicker-$L-ft-$i.txt" 2>/dev/null
  awk -v i="$i" '
    $2=="win" && $6=="cols" { id=$3; px=$4; sub("px","",px); if (px+0 < 150 || px+0 > 520) next
      seen[id]=1; t=$1; n=$7+0
      if (n==0 && !(id in gone)) gone[id]=t
      else if (n>0 && (id in gone)) { bad[id]=bad[id] " " n "cols@" t "ms" } }
    END { any=0
      for (id in seen) { any=1
        if (id in bad) print "cycle " i ": FLICKER panel window " id ": pixels again after they went at " gone[id] " ms:" bad[id]
        else if (id in gone) print "cycle " i ": OK panel window " id ": no pixels after " gone[id] " ms"
        else print "cycle " i ": panel window " id " never went blank within the recording" }
      if (!any) print "cycle " i ": NO DATA (the recorder saw no panel window; is Screen Recording granted?)" }' "$PV"
  front; hotkey; sleep 2
done
save_trace "flicker-$L-trace.log"
