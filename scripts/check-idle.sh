#!/bin/bash
# Starts the built app and the tab host with nothing to do and fails if either
# keeps busy (docs/resources.md). Its own settings folder and sockets, so the
# sidebar and Sync are off: it covers the app and the tab sync, not those.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-dist/betterlink.app}"
work="$(mktemp -d /tmp/bl-idle.XXXXXX)" # short: a socket's path has a limit
pids=()
cleanup() {
  for p in "${pids[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$work/home" "$work/sockets"
make -s .build/measure-resources
export BETTERLINK_HOME="$work/home" BETTERLINK_TABS_SOCKET_DIR="$work/sockets" BETTERLINK_PAGE=tabs
export BETTERLINK_TABS_BROWSER_NAME=Idle

mkfifo "$work/browser"
"$app/Contents/Helpers/betterlink-tabhost" chrome-extension://idle/ < "$work/browser" > "$work/commands" 2> /dev/null &
pids+=($!)
exec 3> "$work/browser" # a browser that says nothing
"$app/Contents/MacOS/Betterlink" > /dev/null 2>&1 &
pids+=($!)
sleep 12 # launch, its window, the first look at the sockets
# The host asks the browser for its tabs when the app connects. Without that the
# tab sync never ran and there is nothing to measure.
grep -aq '"snapshot"' "$work/commands" || { echo "The app never connected to the tab host."; exit 1; }
# Something still settling after launch isn't a regression; one that stays busy
# is. CI's machine was seen at 15 wakeups/s 12 s after launch and at 0.1/s on
# other runs of the same code. Each failed try says what the app was doing.
for try in 1 2 3; do
  if .build/measure-resources --max-cpu 1 --max-wakeups 5 15 "${pids[@]}"; then exit 0; fi
  echo "Busy (try $try of 3). What the app was doing:"
  sample "${pids[1]}" 2 1 -mayDie 2>/dev/null | grep -E "betterlink|Betterlink|DoTimer|CA::|Timer" | head -25 || true
  sleep 15
done
exit 1
