#!/bin/bash
# usage: probe.sh [label]: the macOS window-animation probe (src/probe.swift).
#  1. probe --read: lists each running app's AXEnhancedUserInterface; moves nothing.
#  2. a throwaway Chrome for Testing window (throwaway profile) is opened and probe --pid runs on it: it moves and resizes that one window,
#     puts it back, restores the setting; the browser is then closed. No betterlink app is involved.
# The probe's frames go to $OUT/probe-<label>.csv.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
L=${1:-probe}
browser_for chrome
trap cleanup EXIT; trap 'exit 130' INT TERM
need_perms ax
kill_ours; rm -rf "$RUN"; mkdir -p "$RUN" "$OUT"
echo "### probe --read"; "$T/probe" --read
echo "### probe --pid (throwaway Chrome for Testing window)"
launch_throwaway "$RUN/ble/p" probe 300,150 1200,800
sleep 7; C=$(chrome_pid "$RUN/ble/p"); [ -n "$C" ] || die "the throwaway browser did not start"
front; sleep 1
BETTERLINK_PROBE_CSV="$OUT/probe-$L.csv" "$T/probe" --pid "$C"
