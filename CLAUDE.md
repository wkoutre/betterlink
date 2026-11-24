# CLAUDE.md

## Building

One Swift build at a time, always through make: `make test`, `make build`. The Makefile holds the machine-wide lock, the compiler cap and the Command Line Tools flags (see its comments). Several builds at once, from parallel agents for example, ran a 24 GB Mac out of memory.
