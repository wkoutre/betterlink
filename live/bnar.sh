#!/bin/bash
# usage: bnar.sh <app> <label>: Nick's settings (left, 280, takeover on) for the throwaway Brave only; a Brave window against the screen's right edge at several widths (a laptop half is 756 pt), shown and hidden with the shortcut
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2
browser_for brave; live_init "$A" brave
"$B" agent sidebar.settings.set '{"enabled":true,"shown":false,"side":"left","width":280,"takeOverTabs":true,"browsers":["Brave"]}' | grep -o '"ok":[a-z]*'
start_app; sleep 4; unreg
P=$(app_pid); [ -n "$P" ] || die "the rig app did not start"; "$T/cl" "$P" >/dev/null 2>&1
launch_throwaway "$RUN/ble/p" nar 200,150 900,600
sleep 7; C=$(chrome_pid "$RUN/ble/p"); [ -n "$C" ] || die "the throwaway browser did not start"
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"
pn() { "$T/zo" | awk -v p="pid=$P" '{for(i=1;i<=NF;i++) if($i==p) printf "%s/%s ", $(i+2), $(i+4)}'; }
echo "### $L screen $SW x $SH"
# Brave's own minimum width
"$T/setf" "$C" 300 "$SY" 300 700; sleep 1.2; echo "   Brave's minimum width: asked 300, got $(fr | awk '{print $3}')"
for w in 1028 900 800 780 756 700 600; do front; "$T/setf" "$C" $((SX+SW-w)) "$SY" $w "$SH"; sleep 1.5; a=$(fr); front; sleep .4; hotkey; sleep 2.2; b=$(fr); p=$(pn); front; sleep .3; hotkey; sleep 2.2; c=$(fr)
 ok=OK; [ "$a" = "$c" ] || ok=DIFF; read bx by bw bh <<< "$b"; off=""; [ $((bx+bw)) -gt $((SX+SW+1)) ] && off=" PAST THE RIGHT EDGE by $((bx+bw-SX-SW))"
 echo "$ok width $w | before $a | shown $b panel $p$off | hidden $c"; done
save_trace "bnar-$L-trace.log"
