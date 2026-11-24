# CLAUDE.md

## Building

Build and test through the Makefile (`make test`, `make build`). Its `SWIFT_JOBS` variable caps how many compiler processes SwiftPM runs at once. A bare `swift build` or `swift test` has no cap and can run the machine out of memory, so when you call SwiftPM directly, pass it the flags `SWIFT_JOBS` holds in the `Makefile`.
