# Build artefacts live outside the repo: this folder is cloud-synced and a
# Swift build directory is large and churns constantly.
SCRATCH ?= $(HOME)/Library/Caches/satz-build
APP     := dist/satz.app
# Where the bundle is put together and signed, outside the synced folder.
STAGE   := $(SCRATCH)/bundle/satz.app
BIN     := $(SCRATCH)/release/SatzMac

UNIVERSAL ?= $(HOME)/Library/Caches/satz-universal

# sherpa-onnx (Apache-2.0, k2-fsa): the second engine for "Lokal", running
# Parakeet, Canary, Moonshine and SenseVoice. The release's universal C
# libraries and the matching header, fetched once and checked against their
# SHA-256; never committed (vendor/ ignores itself).
SHERPA_VERSION := 1.13.8
SHERPA_LIBS    := sherpa-onnx-v$(SHERPA_VERSION)-osx-universal2-shared-no-tts-lib
SHERPA_LIBS_SHA := bdcc7c266d355697584dd4efb9dc766e45e18e87cec1fc553002a32cfcfab9a7
SHERPA_HEADER_SHA := 2a1b95084be8fd1deb3228fcad2fd3f7f0258b64582f7402281ec174c7b7f4ce
SHERPA := vendor/sherpa-onnx
SHERPA_READY := $(SHERPA)/ready-$(SHERPA_VERSION)
# Only these two: the C API and the ONNX Runtime it runs on.
SHERPA_DYLIBS := $(SHERPA)/lib/libsherpa-onnx-c-api.dylib $(SHERPA)/lib/libonnxruntime.dylib

.PHONY: app bundle share run test hero showcase icon clean sherpa

app: $(SHERPA_READY)
	swift build -c release --scratch-path "$(SCRATCH)"
	$(MAKE) bundle

# For another Mac: Apple chip and Intel in one app, zipped for AirDrop.
share: $(SHERPA_READY)
	swift build -c release --arch arm64 --arch x86_64 --scratch-path "$(UNIVERSAL)"
	$(MAKE) bundle BIN="$(UNIVERSAL)/out/Products/Release/SatzMac"
	rm -f dist/satz.zip
	# Checked and zipped from the staging copy: Finder never shows it (an
	# "Icon\r" it leaves in an app breaks the seal, the download would count
	# as damaged), and the sync never stamps it.
	codesign --verify --deep --strict "$(STAGE)"
	# Without the files' extended attributes: as ._ files they land inside the
	# bundle with any unzip but Finder's.
	ditto -c -k --norsrc --noextattr --keepParent "$(STAGE)" dist/satz.zip
	@echo "built dist/satz.zip"

bundle:
	rm -rf "$(STAGE)"
	mkdir -p "$(STAGE)/Contents/MacOS" "$(STAGE)/Contents/Resources"
	cp "$(BIN)" "$(STAGE)/Contents/MacOS/satz"
	cp Resources/Info.plist "$(STAGE)/Contents/Info.plist"
	cp -R Resources/Fonts "$(STAGE)/Contents/Resources/Fonts"
	cp Resources/AppIcon.icns "$(STAGE)/Contents/Resources/AppIcon.icns"
	cp -R Resources/en.lproj Resources/de.lproj "$(STAGE)/Contents/Resources/"
	# The clip a local model is timed with, and where it comes from.
	cp Resources/speedtest.wav Resources/speedtest.txt "$(STAGE)/Contents/Resources/"
	# Reads what is playing, from inside /usr/bin/perl (see now-playing.m).
	clang -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -framework Foundation \
		Resources/NowPlaying/now-playing.m -o "$(STAGE)/Contents/Resources/now-playing.dylib"
	cp Resources/NowPlaying/now-playing.pl "$(STAGE)/Contents/Resources/"
	# sherpa-onnx, found through the binary's rpath @executable_path/../Frameworks.
	# Nested code is signed before the bundle that seals it.
	mkdir -p "$(STAGE)/Contents/Frameworks"
	cp $(SHERPA_DYLIBS) "$(STAGE)/Contents/Frameworks/"
	xattr -cr "$(STAGE)/Contents/Frameworks"
	codesign --force --sign - "$(STAGE)"/Contents/Frameworks/*.dylib
	# The repo is cloud-synced, which stamps extended attributes onto every
	# file. codesign refuses to sign a bundle carrying them.
	xattr -cr "$(STAGE)"
	# An ad-hoc signature's designated requirement is normally its cdhash, which
	# changes on every build. macOS keys the Accessibility and Microphone grants
	# and the Keychain item's access list on that requirement, so every rebuild
	# silently revoked them. Pinning it to the bundle identifier keeps the grants.
	# Fine for building on your own Mac; a release needs a real Developer ID.
	codesign --force --sign - --identifier plus.dpa.satz \
		--requirements '=designated => identifier "plus.dpa.satz"' "$(STAGE)"
	# Built and signed outside the synced folder, then copied over whole: the
	# sync stamps a new bundle folder a moment after it appears, and with
	# sherpa-onnx's libraries the signing took long enough to be hit by it.
	rm -rf "$(APP)"
	mkdir -p dist
	ditto "$(STAGE)" "$(APP)"
	@echo "built $(APP)"

# Quits the running copy first: open on an app that is already running only
# brings the old binary forward, it does not launch the new one.
run: app
	-pkill -x satz
	@sleep 0.5
	open "$(APP)"

test: $(SHERPA_READY)
	swift test --scratch-path "$(SCRATCH)"

sherpa: $(SHERPA_READY)

$(SHERPA_READY):
	rm -rf "$(SHERPA)"
	mkdir -p "$(SHERPA)/lib" "$(SHERPA)/include"
	printf '*\n' > vendor/.gitignore
	curl -fsSL -o "$(SHERPA)/libs.tar.bz2" \
		"https://github.com/k2-fsa/sherpa-onnx/releases/download/v$(SHERPA_VERSION)/$(SHERPA_LIBS).tar.bz2"
	echo "$(SHERPA_LIBS_SHA)  $(SHERPA)/libs.tar.bz2" | shasum -a 256 -c -
	tar -xjf "$(SHERPA)/libs.tar.bz2" -C "$(SHERPA)/lib" --strip-components 2 \
		"$(SHERPA_LIBS)/lib/libsherpa-onnx-c-api.dylib" "$(SHERPA_LIBS)/lib/libonnxruntime.dylib"
	curl -fsSL -o "$(SHERPA)/include/c-api.h" \
		"https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v$(SHERPA_VERSION)/sherpa-onnx/c-api/c-api.h"
	echo "$(SHERPA_HEADER_SHA)  $(SHERPA)/include/c-api.h" | shasum -a 256 -c -
	rm "$(SHERPA)/libs.tar.bz2"
	touch "$(SHERPA_READY)"

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
