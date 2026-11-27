# shellcheck shell=bash
# Shared setup for the live tests. Plain bash 3.2 (the one macOS ships) is enough.
# Every script starts with:   D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
#
# Exit codes the scripts use: 0 done, 1 error, 2 STOP (a permission or another running app needs a person; run-all
# stops there), 3 SKIPPED (a browser or a tool this machine lacks).
[ -n "${D:-}" ] || { echo "lib.sh: set D first" >&2; exit 1; }
T=${LIVE_BIN:-$D/bin}                                                   # the compiled tools (build.sh)
W=${LIVE_WORK:-$(cd "${TMPDIR:-/tmp}" && pwd -P)/betterlink-live}       # rig clone and every temporary folder live here
RUN=$W/run                                                              # BETTERLINK_HOME, throwaway profiles, churn page; removed after every script
RIGDIR=$W/rig                                                           # the clone build.sh builds the app from
SOCK=${LIVE_SOCK:-/tmp/betterlink-live-sock.$(id -u)}                   # short on purpose: a unix socket path is limited to 104 bytes
CHURN=file://$RUN/churn.html                                            # a page whose title counts up every <hash> ms (0 = never)
LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
case "$(basename "$W")" in betterlink-live*) ;; *) echo "lib.sh: the work folder must be named betterlink-live*: $W" >&2; exit 1;; esac
OUT=${LIVE_OUT:-$D/out/adhoc}                                           # where traces and captures go (run-all sets LIVE_OUT)
export BETTERLINK_HOME=$RUN/home BETTERLINK_TABS_SOCKET_DIR=$SOCK BETTERLINK_TOUR=off

die() { echo "$*" >&2; exit 1; }
skip() { echo "SKIPPED: $*"; exit 3; }
stop_for_person() { echo "STOP: $*"; exit 2; }

# A regular expression matching the string literally (for pgrep -f and pkill -f).
rx() { printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|]/\\&/g'; }

# Chrome for Testing as Playwright installs it (the highest chromium-N).
cft_bin() {
  ls -d "$HOME"/Library/Caches/ms-playwright/chromium-*/chrome-mac-arm64/"Google Chrome for Testing.app" 2>/dev/null \
    | sed 's#.*/chromium-\([0-9]*\)/.*#\1 &#' | sort -n | tail -1 | cut -d' ' -f2- | sed 's#$#/Contents/MacOS/Google Chrome for Testing#'
}
BRAVE_BIN=${LIVE_BRAVE:-/Applications/Brave Browser.app/Contents/MacOS/Brave Browser}

# browser_for <chrome|brave>: sets BROWSER (the binary) and NAME (the name betterlink's settings use); skips when it is not installed.
browser_for() {
  case "$1" in
    chrome) BROWSER=$(cft_bin); NAME="Google Chrome for Testing"
            [ -n "$BROWSER" ] && [ -x "$BROWSER" ] || skip "Chrome for Testing is not installed (build.sh prints the command)";;
    brave)  BROWSER=$BRAVE_BIN; NAME=Brave
            [ -x "$BROWSER" ] || skip "/Applications/Brave Browser.app is not installed";;
    *) die "the browser must be chrome or brave, not '$1'";;
  esac
}

# use_app <app>: the app must be the rig build inside the work folder, so every pkill and pgrep below is scoped to it.
use_app() {
  [ -n "${1:-}" ] && [ -x "$1/Contents/MacOS/Betterlink" ] || die "no built app at '${1:-}' (run build.sh first)"
  A=$(cd "$1" && pwd -P); B=$A/Contents/MacOS/Betterlink
  case "$A" in "$W"/*) ;; *) die "refusing to touch an app outside $W: $A";; esac
}

# Processes of ours, and only ours: a throwaway profile under $RUN, and the rig's own app.
kill_ours() {
  pkill -f "user-data-dir=$(rx "$RUN")/" 2>/dev/null
  pkill -f "$(rx "${A:-$RIGDIR/dist/betterlink.app}")/Contents/" 2>/dev/null
  return 0
}
unreg() { "$LSREG" -u "${A:-$RIGDIR/dist/betterlink.app}" 2>/dev/null; }
cleanup() {
  kill_ours; sleep 1
  case "$RUN" in "$W"/run) rm -rf "$RUN";; esac
  rm -rf "$SOCK"
  unreg
  return 0
}

# Other copies of what the sidebar attaches by bundle id would be attached too, so refuse to run beside them.
others() {   # others <executable path suffix>: running processes whose executable ends with it (not a shell that merely mentions it), minus ours
  ps -axo pid=,command= | awk -v s="$1" -v run="user-data-dir=$RUN/" -v rig="$RIGDIR/" '{
    c=$0; sub(/^ *[0-9]+ /,"",c); i=index(c,s)
    if (i==0 || substr(c,1,1)!="/") next
    if (index(substr(c,1,i-1)," -")>0) next
    r=substr(c,i+length(s),1); if (r!="" && r!=" ") next
    if (index(c,run)>0 || index(c,rig)>0) next
    print }'
}
preflight() {   # preflight [chrome|brave]
  local o
  o=$(others "/Contents/MacOS/Betterlink")
  [ -z "$o" ] || skip_or_stop "betterlink is already running outside the rig, and two copies would fight over the shortcut and the windows. Quit it, then run again. Seen: $(echo "$o" | head -2 | cut -c1-160)"
  case "${1:-}" in
    chrome) o=$(others "Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")
            [ -z "$o" ] || skip_or_stop "another Chrome for Testing is running (for example a Playwright browser); the sidebar would attach to its windows. Close it, then run again. Seen: $(echo "$o" | head -2 | cut -c1-160)";;
    brave)  o=$(others "Brave Browser.app/Contents/MacOS/Brave Browser")
            [ -z "$o" ] || skip_or_stop "your own Brave is running; the sidebar would attach to its windows. Quit it, then run again. Seen: $(echo "$o" | head -2 | cut -c1-160)";;
  esac
  local bid sc
  bid=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$A/Contents/Info.plist" 2>/dev/null)
  sc=$(defaults read "$bid" sidebar.shortcut 2>/dev/null)   # read only; this never writes the preference domain
  [ -z "$sc" ] || echo "WARNING: $bid has its own sidebar.shortcut saved in this Mac's preferences; the shortcut steps assume control+option+S and may not toggle."
}
skip_or_stop() { echo "SKIPPED: $*"; exit 3; }

# need_perms ax|sr...: the terminal needs Accessibility (every script) and Screen Recording (pv60, flicker, atmin3).
# perm only asks macOS; it never shows a prompt. If one is missing, STOP: a person grants it, nobody clicks a prompt.
need_perms() {
  local p; p=$("$T/perm"); local want
  for want in "$@"; do
    case "$want" in
      ax) case "$p" in *accessibility=true*) ;; *) stop_for_person "this terminal does not have Accessibility (System Settings > Privacy & Security > Accessibility). Ask Nick; do not click any prompt.";; esac;;
      sr) case "$p" in *screenrecording=true*) ;; *) stop_for_person "this terminal does not have Screen Recording (System Settings > Privacy & Security > Screen & System Audio Recording). Ask Nick; do not click any prompt.";; esac;;
    esac
  done
}

# live_init <app> [chrome|brave] [perms...]: the start of every script that runs the rig.
live_init() {
  local a=$1 k=${2:-}; shift; [ $# -gt 0 ] && shift
  use_app "$a"
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  kill_ours
  preflight "$k"
  need_perms ax "$@"
  rm -rf "$RUN"; mkdir -p "$RUN/home" "$SOCK"
}

launch_throwaway() {   # launch_throwaway <profile dir under $RUN> <title> <x,y> <w,h>: a browser of its own, a throwaway profile, one window
  mkdir -p "$1"
  nohup "$BROWSER" --user-data-dir="$1" --use-mock-keychain --password-store=basic --no-first-run --no-default-browser-check --window-position="$3" --window-size="$4" "data:text/html,<title>$2</title>$2" >/dev/null 2>&1 &
}
chrome_pid() { pgrep -f "user-data-dir=$(rx "$1")" | head -1; }     # the browser started with that throwaway profile
app_pid() { pgrep -f "$(rx "$A")/Contents/MacOS/Betterlink" | head -1; }
start_app() { open -n -g --env BETTERLINK_TRACE=1 --env BETTERLINK_TOUR=off --env BETTERLINK_HOME="$RUN/home" --env BETTERLINK_TABS_SOCKET_DIR="$SOCK" "$A"; }
set_() { "$B" agent sidebar.settings.set "$1" >/dev/null; }
front() { "$T/ax" "$C" front >/dev/null; }                            # C: the throwaway browser's pid
# The shortcut goes to the frontmost app, so it is only sent when that is the throwaway browser; otherwise the step is skipped.
hotkey() {
  local f; f=$("$T/fp")
  if [ -n "${C:-}" ] && [ "$f" = "$C" ]; then "$T/hk" "$C" >/dev/null
  else echo "SKIPPED hotkey: the frontmost app is pid $f, not the throwaway browser (pid ${C:-none})"; fi
}
fr() { "$T/ax" "$C" frames | sed 's/.*(//;s/[,)]//g;s/-0\.0/0.0/g;s/\.0//g' | head -1; }   # the browser's first window: x y w h
save_trace() { mkdir -p "$OUT"; cp "$RUN/home/trace.log" "$OUT/$1" 2>/dev/null || echo "(no trace.log in $RUN/home)"; }
