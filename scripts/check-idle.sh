#!/bin/bash
# Starts the built app and the tab host with nothing to do and fails if either
# keeps busy (docs/resources.md). Its own settings folder, sockets and Sync
# folder, so nothing of yours is read or written.
#
# Sync is on, with a folder of its own. The sidebar is on only when
# CHECK_IDLE_SIDEBAR names a Chromium browser's app (CI does): the script then
# starts that browser with a profile of its own and the sidebar attaches to it.
# It attaches to EVERY window of that browser, resizes them and switches their
# tabs to vertical, so the script refuses to start while that browser is
# already running: on your own Mac name one you don't have open.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-dist/betterlink.app}"
work="$(mktemp -d /tmp/bl-idle.XXXXXX)" # short: a socket's path has a limit
pids=()
browser_pid="" suite=""
cleanup() {
  set +e # nothing here decides whether the check passed
  for p in "${pids[@]:-}" "$browser_pid"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
  for p in "${pids[@]:-}" "$browser_pid"; do [ -n "$p" ] && wait "$p" 2>/dev/null; done
  [ -n "$suite" ] && defaults delete "$suite" > /dev/null 2>&1
  # A browser's helpers go on writing to its profile for a moment after it quits.
  for _ in 1 2 3 4 5; do rm -rf "$work" 2>/dev/null && break; sleep 1; done
}
trap cleanup EXIT
mkdir -p "$work/home" "$work/sockets" "$work/sync"
make -s .build/measure-resources .build/idle-probe
export BETTERLINK_HOME="$work/home" BETTERLINK_TABS_SOCKET_DIR="$work/sockets" BETTERLINK_PAGE=tabs
export BETTERLINK_TABS_BROWSER_NAME=Idle
# A new settings folder would open on the first-run tour; this measures the pages.
export BETTERLINK_TOUR=off

# This Mac's settings for a BETTERLINK_HOME live in a preferences domain named
# after the folder (MenuBarIcon.developmentSuite): an id file inside it, and
# its inode. Made here first, so the app finds Sync and the sidebar turned on.
id="$(uuidgen)"
printf %s "$id" > "$work/home/.preferences-id"
suite="com.wkoutre.betterlink.development.$id.$(stat -f %i "$work/home")"
defaults write "$suite" sync.folder -string "$work/sync"
browser="${CHECK_IDLE_SIDEBAR:-}"
if [ -n "$browser" ]; then
  plist="$browser/Contents/Info.plist"
  bundle="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
  binary="$browser/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
  # Only a Chromium browser takes --user-data-dir: another would open with
  # your own profile.
  ls -d "$browser/Contents/Frameworks/"*" Framework.framework" > /dev/null 2>&1 \
    || { echo "$browser is not a Chromium browser."; exit 1; }
  # Its windows already open would get sidebars too, and be resized.
  # (Read whole before grep: a grep that stops early fails the pipe.)
  running="$(ps -axo comm=; lsappinfo list 2> /dev/null || true)"
  if grep -Fxq "$binary" <<< "$running" || grep -Fq "bundleID=\"$bundle\"" <<< "$running"; then
    echo "$bundle is already running: name a browser you don't have open."
    exit 1
  fi
  defaults write "$suite" sidebar.enabled -bool true
  defaults write "$suite" sidebar.browsers -array "$bundle" # this browser only
  "$binary" --user-data-dir="$work/profile" --no-first-run --no-default-browser-check --use-mock-keychain \
    about:blank > /dev/null 2>&1 &
  browser_pid=$!
  sleep 5 # its window, before the app looks for it
fi

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
# Sync writes this Mac's file when it first runs. Without it Sync never
# started, and its watchers and timer are not in what is measured.
ls "$work/sync/betterlink-sync/v1/devices/"*.json > /dev/null 2>&1 || { echo "Sync never wrote this Mac's file: it is not on."; exit 1; }
if [ -n "$browser" ]; then
  # The sidebar is a second window of the app, beside the browser's. Without
  # it the sidebar never attached (no Accessibility for what started this
  # script, or no browser window), and it is not in what is measured.
  probe="$(.build/idle-probe "${pids[1]}")"
  echo "$probe"
  windows="$(awk '/^windows/ { print $2 }' <<< "$probe")"
  [ "${windows:-0}" -ge 2 ] || { echo "The sidebar never attached to $bundle."; exit 1; }
fi
# Three looks of 15 s; one within the limits passes. A CI machine can take a
# while to settle after a launch, and a busy look there says nothing about idle.
# Something that keeps the app busy is over the limits in every look. A look
# over the limits prints what the app was doing, so the log names it.
for look in 1 2 3; do
  .build/measure-resources --max-cpu 1 --max-wakeups 5 15 "${pids[@]}" && exit 0
  echo "::group::What the app was doing after look $look"
  sample "${pids[1]}" 3 -file "$work/sample.txt" > /dev/null 2>&1 && cat "$work/sample.txt" || echo "(no sample)"
  echo "::endgroup::"
done
echo "Still busy after three looks."
exit 1
