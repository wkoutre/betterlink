# CLAUDE.md

## Building

One Swift build at a time, always through make: `make test`, `make build`. The Makefile runs SwiftPM under a machine-wide lock (`SWIFTPM_LOCK`, so a second build waits for the first), caps its compiler processes (`SWIFT_JOBS`), and adds the swift-testing paths a Mac with only the Command Line Tools needs (`SWIFT_TEST_FLAGS`). Several builds at once, from parallel agents for example, ran a 24 GB Mac out of memory. Don't start builds in parallel, and don't run a bare `swift build` or `swift test`; if you must call SwiftPM directly, run it under `SWIFTPM_LOCK` with the `SWIFT_JOBS` flags, as the Makefile does.
