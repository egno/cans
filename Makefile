APP := build/Cans.app
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')

.PHONY: build test app install release cask run log clean

build:
	swift build

test:
	swift test

app:
	scripts/bundle.sh $(VERSION)

# Replaces /Applications/Cans.app with a fresh build and starts it.
install: app
	-pkill -x Cans; while pgrep -x Cans >/dev/null; do sleep 0.2; done
	rm -rf /Applications/Cans.app
	cp -R $(APP) /Applications/Cans.app
	open /Applications/Cans.app

# dist/Cans-<version>.dmg and .zip for a GitHub release: make release VERSION=0.2.0
release:
	scripts/release.sh $(VERSION)

# Casks/cans.rb in the Homebrew tap for this version's DMG: make cask TAP=~/proj/homebrew-tap
cask:
	scripts/cask.sh

run: build
	swift run Cans

log:
	/usr/bin/log stream --level info --predicate 'subsystem == "io.github.egno.cans"'

clean:
	rm -rf .build build dist
