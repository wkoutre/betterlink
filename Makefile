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

# The certificate a local build is signed with (scripts/sign.sh): a Developer
# ID Application identity from the keychain, by its SHA-1 hash (two
# certificates can share a name). macOS then matches the build by
# bundle id and team, as it does the release, so the build keeps its
# permissions across rebuilds. None, or CI, leaves it ad-hoc signed. Looked up
# only when the build recipe uses it, at most once per make run. Override with
# `make build DEV_SIGN_IDENTITY=` (empty: ad hoc).
ifdef CI
DEV_SIGN_IDENTITY ?=
else
DEV_SIGN_IDENTITY ?= $(eval DEV_SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Developer ID Application: ' | awk '{print $$2}'))$(DEV_SIGN_IDENTITY)
endif

# With only the Command Line Tools (no Xcode), swift-testing sits outside
# SwiftPM's default search paths, so `swift test` fails with "no such module
# 'Testing'". Point it there; with Xcode selected this adds nothing.
DEVELOPER_DIR ?= $(shell xcode-select -p 2>/dev/null)
CLT_FRAMEWORKS = $(DEVELOPER_DIR)/Library/Developer/Frameworks
ifeq ($(DEVELOPER_DIR)$(wildcard $(CLT_FRAMEWORKS)/Testing.framework),/Library/Developer/CommandLineTools$(CLT_FRAMEWORKS)/Testing.framework)
SWIFT_TEST_FLAGS ?= -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) -Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) -Xlinker -rpath -Xlinker $(DEVELOPER_DIR)/Library/Developer/usr/lib
endif

.PHONY: fetch tokens icon cli build test test-cli test-tabs check-idle install run clean

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

.build/measure-resources: scripts/measure-resources.swift
	mkdir -p .build
	$(SWIFTPM_LOCK) swiftc -O $< -o $@

# Fails when the built app (tab sync on, sidebar and Sync off) or the tab host
# keeps busy while nothing happens (scripts/check-idle.sh). Opens the app's
# window for half a minute.
check-idle: build
	./scripts/check-idle.sh

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
	# The Tabs extension rides in the app, which keeps a copy where browsers
	# load it from (ExtensionCopy). The same files the store zip holds, plus
	# the manifest's key, so an unpacked copy has the store item's id.
	mkdir -p $(CONTENTS)/Resources/browser-extension/icons
	cp browser-extension/manifest.json browser-extension/background.js browser-extension/bridge.js $(CONTENTS)/Resources/browser-extension/
	cp browser-extension/icons/*.png $(CONTENTS)/Resources/browser-extension/icons/
	cp .build/betterlink-cli $(CONTENTS)/Helpers/betterlink
	cp .build/release/betterlink-tabhost $(CONTENTS)/Helpers/betterlink-tabhost
	# Sign the nested helpers first, then the app around them.
	codesign --force --sign - $(CONTENTS)/Helpers/betterlink
	codesign --force --sign - $(CONTENTS)/Helpers/betterlink-tabhost
	codesign --force --sign - $(APP)
	# A local build with a certificate is signed with it too; release.sh
	# (UPDATES=1) signs releases itself.
	if [ "$(UPDATES)" != 1 ] && [ -n "$(DEV_SIGN_IDENTITY)" ]; then scripts/sign.sh "$(DEV_SIGN_IDENTITY)"; fi
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
