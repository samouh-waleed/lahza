# Lahza native app. Everything runs from the command line; the Xcode IDE is never needed.
.DEFAULT_GOAL := help
SHELL := /bin/bash
SIM ?= iPhone 18 Pro
DEST := platform=iOS Simulator,name=$(SIM)
DERIVED := .build/DerivedData
XCB := xcodebuild -project Lahza.xcodeproj -scheme Lahza -destination '$(DEST)' -derivedDataPath $(DERIVED)
KIT := Packages/LahzaKit
APP_ID := com.waleedsamouh.lahza
JOBS ?= 4
# A connected iPhone's UDID (from `make devices`), for `make device`.
DEVICE_ID ?=

.PHONY: help project build test test-kit test-app run devices device clean

help:
	@echo 'make project   regenerate Lahza.xcodeproj from project.yml'
	@echo 'make build     build for the simulator ($(SIM))'
	@echo 'make run       build, install and launch on the simulator'
	@echo 'make test      kit tests on the Mac + app tests on the simulator'
	@echo 'make devices   list connected iPhones and their UDIDs'
	@echo 'make device DEVICE_ID=<udid>   build, sign, install and launch on your iPhone'

project:            ## Regenerate Lahza.xcodeproj from project.yml
	xcodegen generate --spec project.yml --quiet

build: project      ## Build the app for the simulator
	set -o pipefail && $(XCB) build | xcbeautify --quiet

test-kit:           ## Logic tests on the Mac host (fast)
	swift test --package-path $(KIT) --jobs $(JOBS)

test-app: project   ## App-hosted tests on the simulator
	set -o pipefail && $(XCB) test | xcbeautify --quiet

test: test-kit test-app

run: build          ## Install and launch on the simulator
	xcrun simctl boot "$(SIM)" 2>/dev/null || true
	xcrun simctl install "$(SIM)" "$(DERIVED)/Build/Products/Debug-iphonesimulator/Lahza.app"
	xcrun simctl launch "$(SIM)" $(APP_ID)

devices:            ## Connected iPhones (name, iOS version, UDID)
	xcrun xctrace list devices 2>&1 | sed -n '/== Devices ==/,/== Simulators ==/p' | grep -v '==' | grep -v -i 'mac'

# Signs with the profile Xcode saved locally: Xcode 27's command line can't read the Apple ID added in Xcode,
# so -allowProvisioningUpdates fails with "No Accounts". A free (Personal Team) profile lasts 7 days; when it
# expires, press Run once in Xcode with the iPhone selected to renew it, then use this again.
device: project     ## Build, sign (with Xcode's saved profile), install and launch on an iPhone
	@test -n "$(DEVICE_ID)" || { echo 'Set DEVICE_ID to the iPhone UDID from: make devices'; exit 1; }
	set -o pipefail && xcodebuild -project Lahza.xcodeproj -scheme Lahza -configuration Debug -destination 'id=$(DEVICE_ID)' -derivedDataPath $(DERIVED) build | xcbeautify --quiet
	xcrun devicectl device install app --device $(DEVICE_ID) "$(DERIVED)/Build/Products/Debug-iphoneos/Lahza.app"
	xcrun devicectl device process launch --terminate-existing --device $(DEVICE_ID) $(APP_ID)

clean:
	rm -rf .build $(KIT)/.build
