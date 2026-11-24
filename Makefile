APP        = dist/betterlink.app
CONTENTS   = $(APP)/Contents
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

# Caps how much SwiftPM compiles at once: -j limits build tasks, and
# -Xswiftc -j limits the compiler processes each module starts. Uncapped, one
# build ran about 20 compilers at about 650 MB each and ran a 24 GB Mac out of
# memory. CI runs uncapped on its own machine. Override with `make test SWIFT_JOBS=`.
ifdef CI
SWIFT_JOBS ?=
else
SWIFT_JOBS ?= -j 4 -Xswiftc -j2
endif

# One SwiftPM build or test at a time on this machine: a second waits for the
# first (several builds at once ran the Mac above out of memory just the same).
# /usr/bin/lockf ships with macOS; it says when it has to wait, then waits.
# Override with `make test SWIFTPM_LOCK=`.
LOCKFILE = /tmp/betterlink-swiftpm.lock
SWIFTPM_LOCK ?= $(if $(wildcard /usr/bin/lockf),{ /usr/bin/lockf -k -t 0 $(LOCKFILE) true 2>/dev/null || echo "Waiting for another SwiftPM build to finish ($(LOCKFILE))..." >&2; } && /usr/bin/lockf -k $(LOCKFILE))

# With only the Command Line Tools (no Xcode), swift-testing sits outside
# SwiftPM's default search paths, so `swift test` fails with "no such module
# 'Testing'". Point it there; with Xcode selected this adds nothing.
DEVELOPER_DIR ?= $(shell xcode-select -p 2>/dev/null)
CLT_FRAMEWORKS = $(DEVELOPER_DIR)/Library/Developer/Frameworks
ifeq ($(DEVELOPER_DIR)$(wildcard $(CLT_FRAMEWORKS)/Testing.framework),/Library/Developer/CommandLineTools$(CLT_FRAMEWORKS)/Testing.framework)
SWIFT_TEST_FLAGS ?= -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) -Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(DEVELOPER_DIR)/Library/Developer/usr/lib
endif

.PHONY: fetch tokens icon cli build test test-cli test-tabs install run clean

# The TypeScript compiler bundled for config.ts, checksum-pinned.
fetch:
	./scripts/fetch-typescript.sh

# Regenerates the Swift design tokens from Design/tokens.json.
tokens:
	python3 scripts/gen-tokens.py

test: fetch
	python3 scripts/gen-tokens.py --check
	$(SWIFTPM_LOCK) swift test $(SWIFT_JOBS) $(SWIFT_TEST_FLAGS)

# The betterlink command (cli/), compiled with Bun into one executable that
# ships inside the app at Contents/Helpers/betterlink. Apple silicon only,
# like the app.
cli:
	cd cli && bun install --frozen-lockfile
	cd cli && bunx tsc -p .
	cd cli && BETTERLINK_VERSION=$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' ../Info.plist) && \
	  bun build --compile --target=bun-darwin-arm64 \
	    --define "process.env.BETTERLINK_VERSION=\"$$BETTERLINK_VERSION\"" \
	    src/bin.ts --outfile ../.build/betterlink-cli

# Tabs (preview): the extension's bridge, then the whole pipe (extension
# bridge -> real betterlink-tabhost -> real socket client), with Node's runner.
test-tabs:
	$(SWIFTPM_LOCK) swift build --product betterlink-tabhost $(SWIFT_JOBS)
	$(SWIFTPM_LOCK) swift build --product betterlink-tabs $(SWIFT_JOBS)
	node --test browser-extension/tests/*.test.mjs e2e/*.test.mjs

# Runs the CLI against the built app and a temporary settings folder.
test-cli: build
	cd cli && bun test

# The app icon, drawn from code (scripts/make-icon.swift) at every size macOS uses.
icon:
	rm -rf .build/AppIcon.iconset
	mkdir -p .build/AppIcon.iconset
	$(SWIFTPM_LOCK) swiftc -O scripts/make-icon.swift -o .build/make-icon
	for s in 16 32 128 256 512; do \
	  .build/make-icon .build/AppIcon.iconset/icon_$${s}x$${s}.png $$s; \
	  .build/make-icon .build/AppIcon.iconset/icon_$${s}x$${s}@2x.png $$((s*2)); \
	done
	iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns

build: fetch icon cli
	# Only the versions Package.resolved pins (Sparkle, by commit): a tag moved
	# upstream fails the build instead of being built in.
	$(SWIFTPM_LOCK) swift build -c release --only-use-versions-from-resolved-file $(SWIFT_JOBS)
	rm -rf $(APP)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Helpers $(CONTENTS)/Resources/typescript/lib
	cp .build/release/Betterlink $(CONTENTS)/MacOS/Betterlink
	# Sparkle (auto-update) ships in Contents/Frameworks; ditto keeps its symlinks.
	mkdir -p $(CONTENTS)/Frameworks
	ditto "$$(swift build -c release --show-bin-path)/Sparkle.framework" $(CONTENTS)/Frameworks/Sparkle.framework
	install_name_tool -add_rpath @executable_path/../Frameworks $(CONTENTS)/MacOS/Betterlink
	cp Info.plist $(CONTENTS)/Info.plist
	# Only release builds (scripts/release.sh sets UPDATES=1) keep the update
	# key; a local build never updates itself into a release.
	if [ "$(UPDATES)" != 1 ]; then /usr/libexec/PlistBuddy -c 'Set :SUPublicEDKey ""' $(CONTENTS)/Info.plist; fi
	cp .build/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	cp Vendor/typescript/typescript.js Vendor/typescript/LICENSE.txt Vendor/typescript/ThirdPartyNoticeText.txt $(CONTENTS)/Resources/typescript/
	cp Vendor/typescript/lib/lib.*.d.ts $(CONTENTS)/Resources/typescript/lib/
	cp LICENSE $(CONTENTS)/Resources/LICENSE
	cp .build/betterlink-cli $(CONTENTS)/Helpers/betterlink
	cp .build/release/betterlink-tabhost $(CONTENTS)/Helpers/betterlink-tabhost
	# Sign the nested helpers first, then the app around them.
	codesign --force --sign - $(CONTENTS)/Helpers/betterlink
	codesign --force --sign - $(CONTENTS)/Helpers/betterlink-tabhost
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

# Copies the app to /Applications and registers it as a browser. Then use
# "Make Default Browser" in its window.
install: build
	-pkill -x Betterlink
	rm -rf /Applications/betterlink.app
	cp -R $(APP) /Applications/betterlink.app
	$(LSREGISTER) -f /Applications/betterlink.app
	open /Applications/betterlink.app

clean:
	rm -rf .build dist
