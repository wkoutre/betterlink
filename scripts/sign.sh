#!/bin/sh
# Signs dist/betterlink.app with a certificate: its nested parts innermost
# first, then the app, with the hardened runtime and the entitlements each part
# needs. One sequence for both uses:
#
#   scripts/sign.sh "<identity>" --release   releases (scripts/release.sh): adds
#       the secure timestamp notarization needs; any failure stops the release.
#   scripts/sign.sh "<identity>"             local builds (`make build`, Makefile
#       DEV_SIGN_IDENTITY): a certificate signature is matched by bundle id and
#       team, which stay the same across rebuilds, so macOS keeps the app's
#       permissions. If signing fails, the app is signed ad hoc again so it
#       still runs, and macOS will ask for its permissions again.
#   scripts/sign.sh "<identity>" --strict    the local signing alone, failing on
#       the first error (what the local mode runs).
set -eu
cd "$(dirname "$0")/.."
ID=$1
MODE=${2:-}
APP=dist/betterlink.app
TS=
if [ "$MODE" = --release ]; then TS=--timestamp; fi

sign() {
  # Sparkle comes signed by its own team; the hardened runtime only loads code
  # from betterlink's team, so sign its parts again, innermost first.
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  for part in "$SPARKLE/XPCServices/Installer.xpc" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"; do
    if [ -e "$part" ]; then codesign --force $TS --options runtime --sign "$ID" "$part"; fi
  done
  if [ -e "$SPARKLE/XPCServices/Downloader.xpc" ]; then
    codesign --force $TS --options runtime --preserve-metadata=entitlements \
      --sign "$ID" "$SPARKLE/XPCServices/Downloader.xpc"
  fi
  codesign --force $TS --options runtime --sign "$ID" "$APP/Contents/Frameworks/Sparkle.framework"
  # The nested command first (a Bun executable: it needs JIT entitlements), then
  # the app (JavaScriptCore runs config.ts in-process and needs allow-jit).
  codesign --force $TS --options runtime \
    --entitlements scripts/cli.entitlements \
    --sign "$ID" "$APP/Contents/Helpers/betterlink"
  # The Tabs host a browser launches over native messaging: plain Swift, no entitlements.
  codesign --force $TS --options runtime \
    --sign "$ID" "$APP/Contents/Helpers/betterlink-tabhost"
  codesign --force $TS --options runtime \
    --entitlements scripts/app.entitlements \
    --sign "$ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
}

if [ "$MODE" = --release ] || [ "$MODE" = --strict ]; then
  sign
# A separate process, so `set -e` stops at the first failed step (it doesn't
# apply inside a function run as an `if` condition).
elif sh "$0" "$ID" --strict; then
  echo "Signed $APP with $ID"
else
  echo "Couldn't sign $APP with $ID (is the keychain locked?). Signing it ad hoc instead: it runs, but macOS will ask for its permissions again." >&2
  codesign --force --deep --sign - "$APP"
fi
