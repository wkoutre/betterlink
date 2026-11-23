APP        = dist/betterlink.app
CONTENTS   = $(APP)/Contents
LSREGISTER = /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister

.PHONY: fetch tokens icon cli build test test-cli install run clean

# The TypeScript compiler bundled for config.ts, checksum-pinned.
fetch:
	./scripts/fetch-typescript.sh

# Regenerates the Swift design tokens from Design/tokens.json.
tokens:
	python3 scripts/gen-tokens.py

test: fetch
	python3 scripts/gen-tokens.py --check
	swift test

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

# Runs the CLI against the built app and a temporary settings folder.
test-cli: build
	cd cli && bun test

# The app icon, drawn from code (scripts/make-icon.swift) at every size macOS uses.
icon:
	rm -rf .build/AppIcon.iconset
	mkdir -p .build/AppIcon.iconset
	swiftc -O scripts/make-icon.swift -o .build/make-icon
	for s in 16 32 128 256 512; do \
	  .build/make-icon .build/AppIcon.iconset/icon_$${s}x$${s}.png $$s; \
	  .build/make-icon .build/AppIcon.iconset/icon_$${s}x$${s}@2x.png $$((s*2)); \
	done
	iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns

build: fetch icon cli
	swift build -c release
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
	# Sign the nested helper first, then the app around it.
	codesign --force --sign - $(CONTENTS)/Helpers/betterlink
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
