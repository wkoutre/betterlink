#!/bin/sh
# Builds the release zip of betterlink.app, with its SHA-256 and a Homebrew
# cask that points at it.
#
# Signing and notarization run only when their variables are set, so the same
# script makes an unsigned dry run on any Mac:
#   SIGN_IDENTITY       "Developer ID Application: <name> (<team id>)", in the keychain
#   NOTARY_KEY          path to an App Store Connect API key (.p8)
#   NOTARY_KEY_ID       that key's id
#   NOTARY_ISSUER       its issuer id
#   UPDATE_KEY          path to the update signing key (scripts/update-key.swift);
#                       signs the zip for Sparkle and writes dist/appcast.xml
# REQUIRE_SIGNING=1 fails instead of falling back to an unsigned build.
#
# Output in dist/: betterlink-<version>.zip, betterlink-macos.zip (the same
# file), SHA256SUMS, betterlink.rb, and appcast.xml when UPDATE_KEY is set.
set -eu
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
APP=dist/betterlink.app
ZIP=dist/betterlink-$VERSION.zip
SIGN_IDENTITY=${SIGN_IDENTITY:-}
NOTARY_KEY=${NOTARY_KEY:-}

NOTARY_KEY_ID=${NOTARY_KEY_ID:-}
NOTARY_ISSUER=${NOTARY_ISSUER:-}
UPDATE_KEY=${UPDATE_KEY:-}
REPO=${GITHUB_REPOSITORY:-wkoutre/betterlink}
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)
PUBLIC_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Info.plist 2>/dev/null || true)

# Sparkle compares CFBundleVersion, so it moves with the version.
if [ "$BUILD" != "$VERSION" ]; then
  echo "Info.plist: CFBundleVersion ($BUILD) must equal CFBundleShortVersionString ($VERSION)." >&2
  exit 1
fi

# Fail before the build, not after it, when notarization can't run.
if [ -n "$NOTARY_KEY" ] && { [ -z "$NOTARY_KEY_ID" ] || [ -z "$NOTARY_ISSUER" ]; }; then
  echo "NOTARY_KEY is set, but NOTARY_KEY_ID or NOTARY_ISSUER is not." >&2
  exit 1
fi
if [ "${REQUIRE_SIGNING:-0}" = 1 ] && { [ -z "$SIGN_IDENTITY" ] || [ -z "$NOTARY_KEY" ] || [ -z "$UPDATE_KEY" ]; }; then
  echo "REQUIRE_SIGNING=1, but SIGN_IDENTITY, NOTARY_KEY or UPDATE_KEY is not set." >&2
  exit 1
fi
if [ -n "$UPDATE_KEY" ]; then
  # A release whose key doesn't match the one shipped apps trust would never install.
  [ -n "$PUBLIC_KEY" ] || { echo "UPDATE_KEY is set, but Info.plist has no SUPublicEDKey." >&2; exit 1; }
  if [ "$(swift scripts/update-key.swift public "$UPDATE_KEY")" != "$PUBLIC_KEY" ]; then
    echo "UPDATE_KEY doesn't match SUPublicEDKey in Info.plist." >&2
    exit 1
  fi
fi

# Every release has its entry in the changelog the app shows, which needs
# the clone's tags and history (actions/checkout with fetch-depth: 0).
python3 scripts/gen-changelog.py --require "$VERSION"

UPDATES=1 make build

# The Tabs extension reaches other Macs inside the app (docs/tabs.md).
for f in manifest.json background.js bridge.js reconnect.js icons/128.png; do
  [ -s "$APP/Contents/Resources/browser-extension/$f" ] || { echo "The app has no browser-extension/$f." >&2; exit 1; }
done
grep -q "\"version\": \"$VERSION\"" "$APP/Contents/Resources/changelog.json" ||
  { echo "The app's changelog has no entry for $VERSION." >&2; exit 1; }

if [ -n "$SIGN_IDENTITY" ]; then
  scripts/sign.sh "$SIGN_IDENTITY" --release
else
  echo "SIGN_IDENTITY not set: the app stays ad-hoc signed (dry run)."
fi

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "$SIGN_IDENTITY" ] && [ -n "$NOTARY_KEY" ]; then
  xcrun notarytool submit "$ZIP" --wait \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER"
  xcrun stapler staple "$APP"
  # Zip again so the download carries the stapled ticket.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute --verbose=2 "$APP"
else
  echo "Notarization skipped: NOTARY_KEY not set or the app is unsigned."
fi

# The same zip under a name that never changes, so a website can always link
# releases/latest/download/betterlink-macos.zip.
cp "$ZIP" dist/betterlink-macos.zip
(cd dist && shasum -a 256 "betterlink-$VERSION.zip" betterlink-macos.zip > SHA256SUMS)
SHA=$(head -1 dist/SHA256SUMS | cut -d' ' -f1)
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" packaging/homebrew/betterlink.rb.in > dist/betterlink.rb

# The Sparkle feed for this one release. Apps read it at
# releases/latest/download/appcast.xml, so it goes live when the draft is
# published. The signature covers the exact zip the feed points at.
if [ -n "$UPDATE_KEY" ]; then
  SIGNATURE=$(swift scripts/update-key.swift sign "$UPDATE_KEY" "$ZIP")
  swift scripts/update-key.swift verify "$PUBLIC_KEY" "$SIGNATURE" "$ZIP"
  LENGTH=$(stat -f %z "$ZIP")
  MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)
  cat > dist/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>betterlink</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>betterlink $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/v$VERSION/betterlink-$VERSION.zip"
                 length="$LENGTH" type="application/octet-stream"
                 sparkle:edSignature="$SIGNATURE"/>
    </item>
  </channel>
</rss>
EOF
  echo "Wrote dist/appcast.xml"
else
  echo "UPDATE_KEY not set: no appcast.xml (dry run)."
fi

echo "Built $ZIP"
cat dist/SHA256SUMS
