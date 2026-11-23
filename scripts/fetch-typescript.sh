#!/bin/sh
# Downloads the TypeScript compiler that betterlink bundles to check and compile
# config.ts, and verifies it against a pinned checksum. 6.0.3 is the last
# release shipped as JavaScript; 7.x is a native binary that JavaScriptCore
# cannot run.
set -eu
VERSION=6.0.3
SHA256=33cd0ee1beaa8c9e9d15a9da836c62ddea4c34a42d7c2d349dbc80d94165d22a
DEST="$(cd "$(dirname "$0")/.." && pwd)/Vendor/typescript"
if [ -f "$DEST/.version" ] && [ "$(cat "$DEST/.version")" = "$VERSION" ]; then exit 0; fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/ts.tgz" "https://registry.npmjs.org/typescript/-/typescript-$VERSION.tgz"
echo "$SHA256  $TMP/ts.tgz" | shasum -a 256 -c - >/dev/null
tar xzf "$TMP/ts.tgz" -C "$TMP"
rm -rf "$DEST"; mkdir -p "$DEST/lib"
cp "$TMP/package/lib/typescript.js" "$DEST/"
cp "$TMP/package/LICENSE.txt" "$TMP/package/ThirdPartyNoticeText.txt" "$DEST/"
cp "$TMP"/package/lib/lib.*.d.ts "$DEST/lib/"
echo "$VERSION" > "$DEST/.version"
echo "TypeScript $VERSION fetched to Vendor/typescript"
