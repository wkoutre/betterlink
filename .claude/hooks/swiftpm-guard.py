#!/usr/bin/env python3
"""PreToolUse hook (Bash): refuses a bare `swift build` or `swift test` in this repo.

Several SwiftPM builds at once ran a 24 GB Mac out of memory. The Makefile runs
SwiftPM under a machine-wide lock with a compiler cap (SWIFTPM_LOCK, SWIFT_JOBS),
so builds go through `make test` / `make build`.

The command is split into the commands it actually runs (at ; && || | ( ) and
newlines, outside quotes), so text that only mentions SwiftPM (a commit message,
a PR body, a search pattern) is never refused. A command is refused when it runs
`swift build` or `swift test` (after any variable assignments, `env` or `xcrun`),
unless that same command starts with lockf or only asks for --show-bin-path.
Exit 2 blocks the call and shows stderr to the agent; anything else allows it,
including a command that cannot be parsed.
"""
import json
import shlex
import sys

PREFIXES = {"env", "xcrun", "command", "time", "nice", "exec"}
SEPARATORS = set(";&|()")


def commands(cmd):
    lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=";&|()")
    lex.whitespace_split = True
    current = []
    for tok in lex:
        if tok and set(tok) <= SEPARATORS:
            if current:
                yield current
            current = []
        else:
            current.append(tok)
    if current:
        yield current


def refused(words):
    i = 0
    while i < len(words) and ("=" in words[i] and not words[i].startswith("-") or words[i] in PREFIXES):
        i += 1
    if i < len(words) and words[i].rsplit("/", 1)[-1] == "lockf":
        return False
    head = words[i:i + 2]
    if len(head) == 2 and head[0].rsplit("/", 1)[-1] == "swift" and head[1] in ("build", "test"):
        return "--show-bin-path" not in words
    return False


def main():
    try:
        cmd = json.load(sys.stdin).get("tool_input", {}).get("command", "")
        runs = list(commands(cmd))
    except Exception:
        return 0  # never block on a malformed event or an unparsable command
    if any(refused(w) for w in runs):
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
