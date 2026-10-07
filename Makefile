# Build artefacts live outside the repo: this folder is cloud-synced and a
# Swift build directory is large and churns constantly.
SCRATCH ?= $(HOME)/Library/Caches/satz-build
APP     := dist/satz.app
BIN     := $(SCRATCH)/release/SatzMac

UNIVERSAL ?= $(HOME)/Library/Caches/satz-universal

.PHONY: app bundle share run test hero showcase icon clean

app:
	swift build -c release --scratch-path "$(SCRATCH)"
	$(MAKE) bundle

# For another Mac: Apple chip and Intel in one app, zipped for AirDrop.
share:
	swift build -c release --arch arm64 --arch x86_64 --scratch-path "$(UNIVERSAL)"
	$(MAKE) bundle BIN="$(UNIVERSAL)/out/Products/Release/SatzMac"
	rm -f dist/satz.zip
	# Without the files' extended attributes: as ._ files they land inside the
	# bundle with any unzip but Finder's.
	ditto -c -k --norsrc --noextattr --keepParent "$(APP)" dist/satz.zip
	@echo "built dist/satz.zip"

bundle:
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)" "$(APP)/Contents/MacOS/satz"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp -R Resources/Fonts "$(APP)/Contents/Resources/Fonts"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp -R Resources/en.lproj Resources/de.lproj "$(APP)/Contents/Resources/"
	# Reads what is playing, from inside /usr/bin/perl (see now-playing.m).
	clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -framework Foundation \
		Resources/NowPlaying/now-playing.m -o "$(APP)/Contents/Resources/now-playing.dylib"
	cp Resources/NowPlaying/now-playing.pl "$(APP)/Contents/Resources/"
	# This folder is cloud-synced, which stamps extended attributes onto every
	# file. codesign refuses to sign a bundle carrying them.
	xattr -cr "$(APP)"
	# An ad-hoc signature's designated requirement is normally its cdhash, which
	# changes on every build. macOS keys the Accessibility and Microphone grants
	# and the Keychain item's access list on that requirement, so every rebuild
	# silently revoked them. Pinning it to the bundle identifier keeps the grants.
	# Fine for building on your own Mac; a release needs a real Developer ID.
	codesign --force --sign - --identifier plus.dpa.satz \
		--requirements '=designated => identifier "plus.dpa.satz"' "$(APP)"
	@echo "built $(APP)"

# Quits the running copy first: open on an app that is already running only
# brings the old binary forward, it does not launch the new one.
run: app
	-pkill -x satz
	@sleep 0.5
	open "$(APP)"

test:
	swift test --scratch-path "$(SCRATCH)"

hero: app
	"$(APP)/Contents/MacOS/satz" --hero assets/hero.png
	@echo "rendered assets/hero.png"

showcase: app
	"$(APP)/Contents/MacOS/satz" --showcase assets/showcase.png
	@echo "rendered assets/showcase.png"

# The icon is drawn by the app itself from the brand mark, then packed.
icon: app
	rm -rf "$(SCRATCH)/AppIcon.iconset"
	"$(APP)/Contents/MacOS/satz" --icon "$(SCRATCH)/AppIcon.iconset"
	iconutil -c icns "$(SCRATCH)/AppIcon.iconset" -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

clean:
	rm -rf "$(SCRATCH)" dist
