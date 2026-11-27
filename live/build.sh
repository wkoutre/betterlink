#!/bin/bash
# usage: build.sh [ref] [checkout]
#   ref       what to build: a branch, tag or commit; default origin/main. Looked up as origin/<ref>, then checkout/<ref> (a local
#             branch of the checkout), then as given (a commit id or tag).
#   checkout  your betterlink clone; default ~/Projects/betterlink. It is only read from: the app is built in a separate clone at
#             $TMPDIR/betterlink-live/rig, never in your checkout.
# 1. Chrome for Testing must be installed (this script never downloads it; it prints the command and stops).
# 2. Compiles every Swift tool in src/ into bin/ with swiftc (nothing else).
# 3. Clones the checkout into the rig folder, checks out the ref, applies rig2.patch (adds Chrome for Testing as a browser betterlink
#    knows) and runs `make build` there. Writes the app's path to $TMPDIR/betterlink-live/app-path and prints it.
# Exit codes: 0 built, 1 error, 4 Chrome for Testing missing.
D=$(cd "$(dirname "$0")" && pwd); . "$D/lib.sh"
REF=${1:-origin/main}; CHECKOUT=${2:-$HOME/Projects/betterlink}

if [ -z "$(cft_bin)" ]; then
  echo "Chrome for Testing is not installed (looked for ~/Library/Caches/ms-playwright/chromium-*/chrome-mac-arm64/Google Chrome for Testing.app)."
  echo "This script never downloads it. Run this yourself, then run build.sh again:"
  echo
  echo "  npx playwright install chromium"
  exit 4
fi

command -v swiftc >/dev/null || die "swiftc not found: install the Xcode Command Line Tools (xcode-select --install)"
mkdir -p "$D/bin"
compile() {
  local n=$1 s="$D/src/$1.swift" o="$D/bin/$1"
  if [ -x "$o" ] && [ ! "$s" -nt "$o" ]; then return 0; fi
  rm -f "$o"
  swiftc -O "$s" -o "$o" 2> "$D/bin/$n.log" && rm -f "$D/bin/$n.log"
}
n=0
for s in "$D"/src/*.swift; do compile "$(basename "$s" .swift)" & n=$((n+1)); [ $((n % 4)) = 0 ] && wait; done
wait
bad=0
for s in "$D"/src/*.swift; do b=$(basename "$s" .swift); [ -x "$D/bin/$b" ] || { echo "swiftc failed for $b:"; cat "$D/bin/$b.log" 2>/dev/null; bad=1; }; done
[ $bad = 0 ] || die "a Swift tool did not compile"
echo "tools: $(ls "$D/bin" | wc -l | tr -d ' ') compiled into $D/bin"

git -C "$CHECKOUT" rev-parse --git-dir >/dev/null 2>&1 || die "not a git checkout: $CHECKOUT"
mkdir -p "$W"
[ "$(cd "$CHECKOUT" && pwd -P)" != "$(cd "$RIGDIR" 2>/dev/null && pwd -P)" ] || die "the checkout must not be the rig clone"
if [ ! -d "$RIGDIR/.git" ]; then rm -rf "$RIGDIR"; git clone --quiet --no-checkout "$CHECKOUT" "$RIGDIR" || die "git clone failed"; fi
git -C "$RIGDIR" remote get-url checkout >/dev/null 2>&1 || git -C "$RIGDIR" remote add checkout "$CHECKOUT"
git -C "$RIGDIR" remote set-url checkout "$CHECKOUT"
UP=$(git -C "$CHECKOUT" remote get-url origin 2>/dev/null); [ -z "$UP" ] || git -C "$RIGDIR" remote set-url origin "$UP"
export GIT_TERMINAL_PROMPT=0
git -C "$RIGDIR" fetch --quiet --tags origin '+refs/heads/*:refs/remotes/origin/*' 2>&1 | tail -2
git -C "$RIGDIR" fetch --quiet --tags checkout '+refs/heads/*:refs/remotes/checkout/*' 2>&1 | tail -2
SHA=
for c in "origin/$REF" "checkout/$REF" "$REF"; do SHA=$(git -C "$RIGDIR" rev-parse --verify --quiet "$c^{commit}") && break; done
if [ -z "$SHA" ]; then git -C "$RIGDIR" fetch --quiet checkout "$REF" 2>/dev/null && SHA=$(git -C "$RIGDIR" rev-parse --verify --quiet FETCH_HEAD^{commit}); fi
[ -n "$SHA" ] || die "cannot find '$REF' in $CHECKOUT or its origin"
git -C "$RIGDIR" reset --hard -q 2>/dev/null; git -C "$RIGDIR" clean -fdq
git -C "$RIGDIR" checkout -q --detach -f "$SHA" || die "checkout of $SHA failed"
echo "ref $REF = $SHA ($(git -C "$RIGDIR" log -1 --format=%s | cut -c1-80))"

# rig2.patch's folder is the rig profile's path relative to ~/Library/Application Support (how betterlink joins dataFolder to it).
base=$HOME/Library/Application\ Support; depth=$(echo "${base#/}" | awk -F/ '{print NF}'); ups=; i=0; while [ $i -lt "$depth" ]; do ups=$ups../; i=$((i+1)); done
REL=$ups${RUN#/}/udd
if /usr/bin/grep -q '"Google Chrome for Testing"' "$RIGDIR/Sources/BetterlinkCore/Profiles.swift"; then
  echo "WARNING: this ref already lists Google Chrome for Testing; rig2.patch skipped, so its profile folder is not the rig's."
else
  sed "s#@UDD_REL@#$REL#" "$D/rig2.patch" > "$W/rig2.applied.patch"
  git -C "$RIGDIR" apply --check "$W/rig2.applied.patch" || die "rig2.patch does not apply to $SHA: Sources/BetterlinkCore/Profiles.swift changed. Update live/rig2.patch (one added Browser line before Safari)."
  git -C "$RIGDIR" apply "$W/rig2.applied.patch" || die "git apply failed"
  echo "rig2.patch applied (Chrome for Testing profile folder $REL)"
fi

# The patched folder must really lead to the rig profile from ~/Library/Application Support, or the sidebar cannot read Chrome for Testing's profile.
mkdir -p "$RUN/udd"
got=$(cd "$HOME/Library/Application Support/$REL" 2>/dev/null && pwd -P); want=$(cd "$RUN/udd" && pwd -P)
rm -rf "$RUN"
[ -n "$got" ] && [ "$got" = "$want" ] || die "dataFolder '$REL' does not resolve to $want from $HOME/Library/Application Support (it resolved to '${got:-nothing}'). Does ~/Library/Application Support exist?"
echo "dataFolder check: ~/Library/Application Support/$REL -> $got"

echo "make build in $RIGDIR (log: $W/build.log) ..."
( cd "$RIGDIR" && make build ) > "$W/build.log" 2>&1; rc=$?
if [ $rc != 0 ]; then tail -25 "$W/build.log"; die "make build failed (rc $rc); full log $W/build.log"; fi
APP=$RIGDIR/dist/betterlink.app
[ -x "$APP/Contents/MacOS/Betterlink" ] || die "make build did not produce $APP"
APP=$(cd "$APP" && pwd -P)
echo "$APP" > "$W/app-path"; echo "$REF $SHA" > "$W/app-ref"
echo "built $APP at $SHA"
