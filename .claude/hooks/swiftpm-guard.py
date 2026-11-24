#!/usr/bin/env python3
"""PreToolUse hook (Bash): refuses SwiftPM builds that skip this repo's build lock.

Several SwiftPM builds at once ran a 24 GB Mac out of memory. The Makefile runs
SwiftPM under a machine-wide lock with a compiler cap (SWIFTPM_LOCK, SWIFT_JOBS),
so builds go through `make test` / `make build`.

It errs toward refusing. Only text the shell never runs is ignored: single-quoted
strings, and the bodies of heredocs whose delimiter is quoted (<<'EOF'), when the
closing delimiter line is there. If the single quotes don't pair up (an apostrophe
in a comment, an escaped quote), nothing is ignored. Double-quoted text is still
checked, since the shell runs $(...) and backticks inside it; write messages that
mention SwiftPM in single quotes or a <<'EOF' heredoc.

In what is left, any SwiftPM build entry point (swift build|test|run, swift-build,
swift-test, swift-run) is refused unless the same command (cut at ; & | and
newlines) runs it under this repo's lock file with the compiler cap, as the
Makefile does, or is `swift build ... --show-bin-path`.
Exit 2 blocks the call and shows stderr to the agent; anything else allows it.
"""
import json
import re
import sys

LOCKFILE = "/tmp/betterlink-swiftpm.lock"
QUOTED_HEREDOC = re.compile(r"<<-?[ \t]*(['\"])([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n(.*?)\n[ \t]*\2[ \t]*(?=\n|$)", re.S)
SINGLE = re.compile(r"'[^']*'")
SEGMENT = re.compile(r"[;&|\n]")
SWIFTPM = re.compile(r"(?<![\w.-])swift(?:\s+|-)(?:build|test|run)\b")
BIN_PATH = re.compile(r"(?<![\w.-])swift\s+build\b[^;&|\n#]*--show-bin-path")


def strip_data(cmd: str) -> str:
    cmd = QUOTED_HEREDOC.sub(lambda m: m.group(0).split("\n", 1)[0] + "\n", cmd)
    if cmd.count("'") % 2 == 0 and "\\'" not in cmd:
        cmd = SINGLE.sub("''", cmd)
    return cmd


def allowed(seg: str) -> bool:
    if BIN_PATH.search(seg) and len(SWIFTPM.findall(seg)) == 1:
        return True
    return re.search(r"(?<![\w.-])lockf\b", seg) is not None and LOCKFILE in seg and "-Xswiftc -j" in seg


def refused(cmd: str) -> bool:
    return any(SWIFTPM.search(seg) and not allowed(seg) for seg in SEGMENT.split(strip_data(cmd)))


def main() -> int:
    try:
        cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
    except Exception:
        return 0  # never block on a malformed event
    if isinstance(cmd, str) and refused(cmd):
        print(
            "Refused: this runs a SwiftPM build outside the repo's machine-wide build lock and "
            "compiler cap. Run `make test` or `make build` (one at a time). To mention SwiftPM in a "
            "message, put it in single quotes or a <<'EOF' heredoc. See CLAUDE.md.",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
