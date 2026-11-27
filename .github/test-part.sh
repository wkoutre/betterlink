#!/bin/bash
# One part of `make test` + `make test-cli`, for CI jobs that run the parts on
# separate machines at once (test.yml's swift-test, release.yml's test).
# Together the parts run everything the two targets do:
#   app       make test, without the sidebar guard's random cases
#   cli       make test-cli
#   guard-K   the sidebar guard's random cases, part K of GUARD_PARTS
#             (BETTERLINK_GUARD_SHARD: every GUARD_PARTS-th case from the K-th)
# One after the other on one machine they took over 10 minutes: the guard's
# 2000 cases run on the main thread, and every other main-thread test waited
# behind them.
#
# GUARD_PARTS must match the guard-K parts the workflow's matrix lists.
# SWIFT_TEST_FLAGS here replaces the Makefile's, which only a Mac with the
# Command Line Tools and no Xcode needs; the runners have Xcode.
set -euo pipefail

part=${1:?usage: test-part.sh app|cli|guard-K}
guard=everyCaseKeepsTheFourRules
parts=${GUARD_PARTS:-2}

case "$part" in
  app) make test SWIFT_TEST_FLAGS="--skip $guard" ;;
  cli) make test-cli ;;
  guard-*)
    k=${part#guard-}
    log=$(mktemp)
    BETTERLINK_GUARD_SHARD="$k/$parts" make test SWIFT_TEST_FLAGS="--filter $guard" | tee "$log"
    # A filter that matched nothing would pass with no cases run.
    grep -q "SidebarGuard: part $k of $parts, [1-9][0-9]* of " "$log" ||
      { echo "::error::The sidebar guard didn't run its part $k of $parts."; exit 1; } ;;
  *) echo "::error::Unknown part $part"; exit 1 ;;
esac
