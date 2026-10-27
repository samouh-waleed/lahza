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

.PHONY: help project build test test-kit test-app run clean

help:
	@echo 'make project   regenerate Lahza.xcodeproj from project.yml'
	@echo 'make build     build for the simulator ($(SIM))'
	@echo 'make run       build, install and launch on the simulator'
	@echo 'make test      kit tests on the Mac + app tests on the simulator'

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

clean:
	rm -rf .build $(KIT)/.build
