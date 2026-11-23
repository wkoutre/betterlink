#!/bin/sh
# Sets CFBundleShortVersionString and CFBundleVersion in Info.plist to the
# same version (Sparkle compares CFBundleVersion, so they move together).
#   scripts/set-version.sh 0.4.0     set an exact version
#   scripts/set-version.sh patch     0.3.1 -> 0.3.2 (also: minor, major)
#   scripts/set-version.sh current   print the version, change nothing
# Prints the new version. Plain perl, so it runs on macOS and Linux runners.
set -eu
cd "$(dirname "$0")/.."

current=$(perl -0ne 'print $1 if m{<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>}' Info.plist)
case "$current" in
  [0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "Info.plist: can't read CFBundleShortVersionString ($current)." >&2; exit 1 ;;
esac
IFS=. read -r major minor patch <<VERSION
$current
VERSION

case "${1:-}" in
  current) echo "$current"; exit 0 ;;
  patch) version="$major.$minor.$((patch + 1))" ;;
  minor) version="$major.$((minor + 1)).0" ;;
  major) version="$((major + 1)).0.0" ;;
  [0-9]*.[0-9]*.[0-9]*) version=$1 ;;
  *) echo "usage: $0 patch|minor|major|X.Y.Z" >&2; exit 2 ;;
esac
printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Not a version: $version" >&2; exit 2; }

V="$version" perl -0pi -e '
  for my $key (qw(CFBundleShortVersionString CFBundleVersion)) {
    s{(<key>\Q$key\E</key>\s*<string>)[^<]*(</string>)}{$1$ENV{V}$2} or die "Info.plist has no $key\n";
  }' Info.plist
echo "$version"
