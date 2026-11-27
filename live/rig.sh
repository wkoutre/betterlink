#!/bin/bash
# usage: rig.sh <app> [chrome args...]
# Starts Chrome for Testing (throwaway profile under $RUN, the Tabs extension from the rig clone loaded) and the rig app,
# and writes "<app pid> <tab host pid> <browser pid>" to $RUN/pids. It leaves them running: the script that called it
# cleans up (cleanup.sh does it by hand). Set EXT to load a different extension folder.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
use_app "$1"; shift
browser_for chrome
mkdir -p "$W"
kill_ours; sleep 2
preflight chrome
rm -rf "$RUN"; mkdir -p "$RUN/home" "$RUN/udd/NativeMessagingHosts" "$SOCK"
echo "{\"name\":\"com.wkoutre.betterlink.tabs\",\"description\":\"t\",\"path\":\"$A/Contents/Helpers/betterlink-tabhost\",\"type\":\"stdio\",\"allowed_origins\":[\"chrome-extension://gjjllnebeeegbipppiclhlomdppbnljh/\"]}" > "$RUN/udd/NativeMessagingHosts/com.wkoutre.betterlink.tabs.json"
"$B" agent sidebar.settings.set '{"enabled":true,"takeOverTabs":false,"browsers":["Google Chrome for Testing"]}' | grep -o '"ok":[a-z]*'
cat > "$RUN/churn.html" <<'H'
<title>tab</title><script>let n=0;const ms=+(location.hash.slice(1)||0);if(ms)setInterval(()=>{document.title='tab '+(++n)},ms)</script>
H
BETTERLINK_TABS_SOCKET_DIR=$SOCK nohup "$BROWSER" --user-data-dir="$RUN/udd" --use-mock-keychain --password-store=basic --no-first-run --no-default-browser-check --disable-background-timer-throttling --disable-renderer-backgrounding --disable-backgrounding-occluded-windows --load-extension="${EXT:-$RIGDIR/browser-extension}" --window-position=200,100 --window-size=1100,800 "$@" >"$RUN/chrome.log" 2>&1 &
sleep 8
start_app; sleep 5
unreg
P=$(app_pid); [ -n "$P" ] || die "the rig app did not start"
"$T/cl" "$P" >/dev/null
C=$(pgrep -f "Google Chrome for Testing --user-data-dir=$(rx "$RUN")/udd" | head -1); [ -n "$C" ] || die "Chrome for Testing did not start"
H=$(pgrep -f "$(rx "$A")/Contents/Helpers/betterlink-tabhost" | head -1)
echo "$P ${H:-0} $C" > "$RUN/pids"; echo pids "$P" "${H:-0}" "$C"
