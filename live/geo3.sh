#!/bin/bash
# usage: geo3.sh <app> <label>: the sidebar shown and hidden (settings, not the shortcut) on a Chrome for Testing window at six places on the screen, both sides; also the window moved while shown, the width changed while shown, rapid toggles
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
A=$1; L=$2
browser_for chrome; live_init "$A" chrome
fw() { fr; }
pn() { "$T/w" "$P" | tr -d '\n' | sed 's/} /}\n/g;s/  */ /g' | grep -v 'Height = 640\|Height = 500' | grep -o 'Width = [0-9]*; X = [0-9-]*' | head -1; }
read SX SY SW SH sc <<< "$("$T/scr" | head -1)"; H2=$((SW/2)); T3=$((SW/3))
bash "$D/rig.sh" "$A" "$CHURN?1#0" >/dev/null; read P H C < "$RUN/pids"; echo "### $L screen $SW x $SH"; "$T/cl" "$P" >/dev/null
for side in left right; do set_ '{"shown":false}'; sleep 1; set_ "{\"side\":\"$side\"}"; sleep 1
for t in "0 $H2" "$H2 $H2" "0 $SW" "0 $T3" "$((SW-T3)) $T3" "$T3 $T3"; do a_=($t); set_ '{"shown":false}'; sleep .8; front; "$T/setf" "$C" $((SX+a_[0])) "$SY" "${a_[1]}" "$SH"; sleep 1; a=$(fw); front; set_ '{"shown":true}'; sleep 1.6; b=$(fw); p=$(pn); set_ '{"shown":false}'; sleep 1.6; c=$(fw); ok=OK; [ "$a" = "$c" ] || ok=DIFF; echo "$ok $side | start $a | shown $b panel $p | hidden $c"
 front; set_ '{"shown":true}'; sleep 1.6; b=($(fw)); "$T/setf" "$C" $((b[0]+17)) $((b[1]+9)) "${b[2]}" $((b[3]-60)); sleep 1.4; m=$(fw); pm=$(pn); set_ '{"shown":false}'; sleep 1.6; echo "     moved: $m panel $pm -> hidden $(fw)"; done
 # edge resize then hide
 set_ '{"shown":false}'; sleep 1; "$T/setf" "$C" "$SX" "$SY" $H2 "$SH"; sleep .8; a=$(fw); front; set_ '{"shown":true}'; sleep 1.4; set_ '{"width":340}'; sleep 1.4; b=$(fw); set_ '{"shown":false}'; sleep 1.4; echo "$([ "$a" = "$(fw)" ] && echo OK || echo DIFF) $side width change while shown: $a -> $b -> $(fw)"; set_ '{"width":280}'; sleep .5
 for i in 1 2 3 4; do set_ '{"shown":true}'; sleep .12; set_ '{"shown":false}'; sleep .12; done; sleep 1.5; echo "$([ "$a" = "$(fw)" ] && echo OK || echo DIFF) $side rapid toggles: $(fw)"
done
save_trace "geo3-$L-trace.log"
