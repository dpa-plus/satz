# Build artefacts live outside the repo: this folder is cloud-synced and a
# Swift build directory is large and churns constantly.
SCRATCH ?= $(HOME)/Library/Caches/satz-build
APP     := dist/satz.app
BIN     := $(SCRATCH)/release/SatzMac

.PHONY: app run test hero clean

app:
	swift build -c release --scratch-path "$(SCRATCH)"
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)" "$(APP)/Contents/MacOS/satz"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp -R Resources/Fonts "$(APP)/Contents/Resources/Fonts"
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

clean:
	rm -rf "$(SCRATCH)" dist
