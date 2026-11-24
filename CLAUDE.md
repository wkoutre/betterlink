# CLAUDE.md

## Building

One Swift build at a time, always through make: `make test`, `make build`. The Makefile holds the machine-wide lock, the compiler cap and the Command Line Tools flags (see its comments); `.claude/hooks/swiftpm-guard.py` refuses a bare `swift build` or `swift test` here.
