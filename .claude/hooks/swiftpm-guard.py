#!/usr/bin/env python3
"""PreToolUse hook (Bash): refuses a bare `swift build` or `swift test` in this repo.

Several SwiftPM builds at once ran a 24 GB Mac out of memory. The Makefile runs
SwiftPM under a machine-wide lock with a compiler cap (SWIFTPM_LOCK, SWIFT_JOBS),
so builds go through `make test` / `make build`.

How it reads a command line:
1. Text that is only data is dropped: heredoc bodies, then quoted strings. So a
   commit message, a PR body or a search pattern that mentions SwiftPM is never
   refused. (A command hidden inside quotes, as in `bash -c "swift build"`, is
   not caught; this guards against mistakes, not deliberate bypasses.)
2. What is left is cut into segments at ; & | ( ) { } and newlines. Any segment
   that runs `swift build` or `swift test` anywhere in it (after a keyword such as
   `do` or `then`, a wrapper such as `sudo`, `timeout 600` or `xcrun --sdk x`, or
   a path such as /usr/bin/swift) is refused, unless that same segment runs it
   under lockf or only asks for --show-bin-path.
Exit 2 blocks the call and shows stderr to the agent; anything else allows it.
"""
import json
import re
import sys

HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n(.*?)(?:\n[ \t]*\2[ \t]*(?=\n|$)|\Z)", re.S)
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", re.S)
SEGMENT = re.compile(r"[;&|(){}\n]")
SWIFTPM = re.compile(r"(?:^|[\s/])swift\s+(?:build|test)\b")


def strip_data(cmd: str) -> str:
    # Keep the heredoc's opening line (the command), drop its body.
    cmd = HEREDOC.sub(lambda m: m.group(0).split("\n", 1)[0] + "\n", cmd)
    return QUOTED.sub("''", cmd)


def refused(cmd: str) -> bool:
    for seg in SEGMENT.split(strip_data(cmd)):
        m = SWIFTPM.search(seg)
        if not m:
            continue
        if "--show-bin-path" in seg or re.search(r"(?:^|[\s/])lockf\b", seg[: m.start() + 1]):
            continue
        return True
    return False


def main() -> int:
    try:
        cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    except Exception:
        return 0  # never block on a malformed event
    if isinstance(cmd, str) and refused(cmd):
        print(
            "Refused: a bare `swift build`/`swift test` skips this repo's machine-wide build lock "
            "and compiler cap. Run `make test` or `make build` (one at a time), or prefix SwiftPM "
            "with the Makefile's SWIFTPM_LOCK and SWIFT_JOBS. See CLAUDE.md.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
