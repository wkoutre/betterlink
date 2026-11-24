#!/bin/sh
# Packs browser-extension/ for the Chrome Web Store.
# Usage: scripts/package-extension.sh [out-dir]   (default: dist)
# Writes <out-dir>/betterlink-tabs-<version>.zip and prints its path.
#
# The zip holds only what the browser runs: the manifest, the two scripts and
# the icons. The manifest's "key" is left out, because the store refuses an
# upload that has one (the store signs the item with its own copy of that key).
set -eu
cd "$(dirname "$0")/.."
out="${1:-dist}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

version="$(node -e '
const fs = require("fs");
const m = JSON.parse(fs.readFileSync("browser-extension/manifest.json", "utf8"));
delete m.key;
fs.writeFileSync(process.argv[1] + "/manifest.json", JSON.stringify(m, null, 2) + "\n");
process.stdout.write(m.version);
' "$stage")"

cp browser-extension/background.js browser-extension/bridge.js "$stage/"
cp -R browser-extension/icons "$stage/icons"

zip="$out/betterlink-tabs-$version.zip"
rm -f "$zip"
(cd "$stage" && zip -q -r -X "$zip" manifest.json background.js bridge.js icons)
echo "$zip"
