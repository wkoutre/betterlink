#!/bin/sh
# Bun compiles the betterlink command that ships inside the signed app, and
# setup-bun fetches Bun by version number alone. This compares the installed
# binary with the checksum of the official build, so a swapped download or a
# poisoned cache can't reach the job that holds the signing keys.
#
# To update Bun: change bun-version in .github/workflows/, then set VERSION and
# SHA256 here. SHA256 is the hash of the `bun` file inside
# bun-darwin-aarch64.zip from https://github.com/oven-sh/bun/releases (check
# the zip itself against that release's SHASUMS256.txt first):
#   unzip -p bun-darwin-aarch64.zip bun-darwin-aarch64/bun | shasum -a 256
set -eu

VERSION=1.4.4
SHA256=0a2237cdcfa0d16ef501d9acca9f0026309ef348bea7393a64e8d1e3609565cc

if [ "$(uname -s)-$(uname -m)" != "Darwin-arm64" ]; then
  echo "check-bun.sh knows only Bun's Apple silicon macOS build; this is $(uname -s)-$(uname -m)." >&2
  exit 1
fi
bun=$(command -v bun) || { echo "bun isn't installed." >&2; exit 1; }
actual=$(shasum -a 256 "$bun" | cut -d' ' -f1)
if [ "$actual" != "$SHA256" ]; then
  {
    echo "Bun at $bun isn't the pinned build."
    echo "  expected $SHA256 (Bun $VERSION)"
    echo "  found    $actual ($("$bun" --version 2>/dev/null || echo unknown))"
    echo "If Bun was updated on purpose, update VERSION and SHA256 in scripts/check-bun.sh."
  } >&2
  exit 1
fi
echo "Bun $VERSION matches its pinned checksum."
