#!/bin/bash
# Sets up the GitHub `release` environment and its seven signing secrets
# (RELEASING.md parts 3 and 4). Run from a betterlink checkout, on the Mac that holds
# the Developer ID:
#
#   bash scripts/set-release-secrets.sh [owner/repo]
#   bash scripts/set-release-secrets.sh --update-key-only [owner/repo]
#
# It asks for each value. Passwords are read without echo and passed to gh
# on stdin, so nothing lands in shell history or the process list.
set -euo pipefail

ONLY_UPDATE_KEY=0
if [ "${1:-}" = "--update-key-only" ]; then ONLY_UPDATE_KEY=1; shift; fi
REPO=${1:-wkoutre/betterlink}
HERE=$(cd "$(dirname "$0")" && pwd)
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }
put() { gh secret set "$1" --env release --repo "$REPO" >/dev/null && echo "  set $1"; }

command -v gh >/dev/null || die "Install the GitHub CLI first: brew install gh"
gh auth status >/dev/null 2>&1 || die "Sign in first: gh auth login"
gh api "repos/$REPO" --jq .full_name >/dev/null || die "Can't reach $REPO with your gh login."

# The key Sparkle checks every update against. Losing it means installed
# copies can never update again, so it is made once and kept.
update_key() {
  say "Update signing key (Sparkle)"
  command -v swift >/dev/null || die "swift is missing: install Xcode or its command line tools."
  [ -f "$HERE/update-key.swift" ] || die "Run this from a betterlink checkout (scripts/update-key.swift is missing)."
  KEY_DEFAULT=~/Desktop/betterlink-update.key
  read -r -p "  Existing update key file, or Enter to make a new one at $KEY_DEFAULT: " KEYFILE
  if [ -z "$KEYFILE" ]; then
    KEYFILE=$KEY_DEFAULT
    PUB=$(swift "$HERE/update-key.swift" keygen "$KEYFILE")
    echo "  made $KEYFILE"
  else
    KEYFILE=${KEYFILE/#\~/$HOME}
    PUB=$(swift "$HERE/update-key.swift" public "$KEYFILE")
  fi
  put SPARKLE_UPDATE_KEY < "$KEYFILE"
  printf '\n  Public key (safe to share; it goes in Info.plist as SUPublicEDKey):\n\n    %s\n' "$PUB"
  printf '\n  Save %s in your password manager now. Without it no update can reach\n  people who already installed betterlink.\n' "$KEYFILE"
}

if [ "$ONLY_UPDATE_KEY" = 1 ]; then
  update_key
  say "Check"
  gh secret list --env release --repo "$REPO"
  exit 0
fi

say "1/5  Environment 'release', limited to v* tags ($REPO)"
gh api -X PUT "repos/$REPO/environments/release" \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true' >/dev/null
if gh api "repos/$REPO/environments/release/deployment-branch-policies" --jq '.branch_policies[] | select(.type=="tag") | .name' | grep -qx 'v\*'; then
  echo "  tag rule v* already there"
else
  gh api -X POST "repos/$REPO/environments/release/deployment-branch-policies" -f name='v*' -f type=tag >/dev/null
  echo "  added tag rule v*"
fi

say "2/5  Developer ID certificate (.p12)"
P12_DEFAULT=~/Desktop/betterlink-devid.p12
read -r -p "  Path to the exported .p12 [$P12_DEFAULT]: " P12
P12=${P12:-$P12_DEFAULT}; P12=${P12/#\~/$HOME}
[ -f "$P12" ] || die "No file at $P12. Export it from Keychain Access (RELEASING.md part 1, step 5)."
read -r -s -p "  The password you set when exporting it: " PW; echo
[ -n "$PW" ] || die "Empty password. Export again and set one."
# Prove the password opens the file, using a throwaway keychain (never login).
TMPKC=$(mktemp -d)/check.keychain-db
security create-keychain -p check "$TMPKC" >/dev/null
trap 'security delete-keychain "$TMPKC" >/dev/null 2>&1 || true' EXIT
security import "$P12" -k "$TMPKC" -P "$PW" -T /usr/bin/codesign >/dev/null 2>&1 \
  || die "That password doesn't open $P12. Try again, or export a fresh .p12 with a new password."
IDENT=$(security find-identity -p codesigning "$TMPKC" | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
[ -n "$IDENT" ] || die "$P12 has no Developer ID Application certificate with its private key."
echo "  password OK; it holds: $IDENT"
base64 -i "$P12" | put MACOS_CERTIFICATE_P12
printf '%s' "$PW" | put MACOS_CERTIFICATE_PASSWORD
unset PW

say "3/5  Signing identity"
printf '%s' "$IDENT" | put MACOS_SIGN_IDENTITY

say "4/5  Notarization key (.p8)"
P8_GUESS=$(ls -t ~/Desktop/AuthKey_*.p8 ~/Downloads/AuthKey_*.p8 2>/dev/null | head -1 || true)
read -r -p "  Path to AuthKey_XXXXXXXXXX.p8 [${P8_GUESS:-none found}]: " P8
P8=${P8:-$P8_GUESS}; P8=${P8/#\~/$HOME}
[ -n "$P8" ] && [ -f "$P8" ] || die "No .p8 file. Make one in App Store Connect (RELEASING.md part 2)."
KEY_ID=$(basename "$P8" | sed -n 's/^AuthKey_\([A-Z0-9]\{10\}\)\.p8$/\1/p')
if [ -n "$KEY_ID" ]; then
  echo "  Key ID from the file name: $KEY_ID"
else
  read -r -p "  Key ID (10 characters): " KEY_ID
fi
[[ "$KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || die "A Key ID is 10 letters and digits."
base64 -i "$P8" | put NOTARY_KEY_P8
printf '%s' "$KEY_ID" | put NOTARY_KEY_ID
read -r -p "  Issuer ID (the UUID above the keys table): " ISSUER
[[ "$ISSUER" =~ ^[0-9a-fA-F-]{36}$ ]] || die "An Issuer ID looks like 57246542-96fe-1a63-e053-0824d011072a."
printf '%s' "$ISSUER" | put NOTARY_ISSUER

update_key

say "5/5  Check"
gh secret list --env release --repo "$REPO"
echo
echo "Done. Keep the .p12, its password and the .p8 in your password manager, then delete the files:"
echo "  rm \"$P12\" \"$P8\""
