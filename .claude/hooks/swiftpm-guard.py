#!/usr/bin/env python3
"""PreToolUse hook (Bash): refuses a bare `swift build` or `swift test` in this repo.

Several SwiftPM builds at once ran a 24 GB Mac out of memory. The Makefile runs
SwiftPM under a machine-wide lock with a compiler cap (SWIFTPM_LOCK, SWIFT_JOBS),
so builds go through `make test` / `make build`. A command that runs SwiftPM
under /usr/bin/lockf itself, or only asks for --show-bin-path, is allowed.
Exit 2 blocks the call and shows stderr to the agent; anything else allows it.
"""
import json
import re
import sys

try:
    cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
except Exception:
    sys.exit(0)  # never block on a malformed event

for m in re.finditer(r"\bswift\s+(build|test)\b[^;&|\n]*", cmd):
    if "--show-bin-path" in m.group(0):
        continue
    if "lockf" in cmd[: m.start()]:
        continue
    print(
        "Refused: a bare `swift build`/`swift test` skips this repo's machine-wide build lock "
        "and compiler cap. Run `make test` or `make build` (one at a time), or prefix SwiftPM "
        "with the Makefile's SWIFTPM_LOCK and SWIFT_JOBS. See CLAUDE.md.",
        file=sys.stderr,
    )
    sys.exit(2)
sys.exit(0)
