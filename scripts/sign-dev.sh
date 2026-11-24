#!/bin/sh
# Signs a local build (dist/betterlink.app) with a real certificate, so macOS
# keeps its Accessibility and other privacy grants across rebuilds. An ad-hoc
# signature changes with every build, and macOS asks again each time; a
# certificate signature is matched by bundle id and team, which stay the same.
# Same parts and entitlements as scripts/release.sh, without the timestamp or
# notarization. `make build` runs it when it finds an identity (Makefile,
# DEV_SIGN_IDENTITY). Usage: scripts/sign-dev.sh "<identity>"
set -eu
ID=$1
APP=dist/betterlink.app
SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for p in "$SP/XPCServices/Installer.xpc" "$SP/Autoupdate" "$SP/Updater.app"; do
  if [ -e "$p" ]; then codesign --force --options runtime --sign "$ID" "$p"; fi
done
if [ -e "$SP/XPCServices/Downloader.xpc" ]; then
  codesign --force --options runtime --preserve-metadata=entitlements --sign "$ID" "$SP/XPCServices/Downloader.xpc"
fi
codesign --force --options runtime --sign "$ID" "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --options runtime --entitlements scripts/cli.entitlements --sign "$ID" "$APP/Contents/Helpers/betterlink"
codesign --force --options runtime --sign "$ID" "$APP/Contents/Helpers/betterlink-tabhost"
codesign --force --options runtime --entitlements scripts/app.entitlements --sign "$ID" "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed $APP with $ID"
