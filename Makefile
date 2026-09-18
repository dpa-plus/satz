# Build artefacts live outside the repo: this folder is cloud-synced and a
# Swift build directory is large and churns constantly.
SCRATCH ?= $(HOME)/Library/Caches/satz-build
APP     := dist/satz.app
BIN     := $(SCRATCH)/release/SatzMac

.PHONY: app run test clean

app:
	swift build -c release --scratch-path "$(SCRATCH)"
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	cp "$(BIN)" "$(APP)/Contents/MacOS/satz"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	codesign --force --sign - "$(APP)"
	@echo "built $(APP)"

run: app
	open "$(APP)"

test:
	swift test --scratch-path "$(SCRATCH)"

clean:
	rm -rf "$(SCRATCH)" dist
