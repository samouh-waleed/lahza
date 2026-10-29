# Lahza native app. Everything runs from the command line; the Xcode IDE is never needed.
.DEFAULT_GOAL := help
SHELL := /bin/bash
SIM ?= iPhone 18 Pro
DEST := platform=iOS Simulator,name=$(SIM)
DERIVED := .build/DerivedData
XCB := xcodebuild -project Lahza.xcodeproj -scheme Lahza -destination '$(DEST)' -derivedDataPath $(DERIVED) -onlyUsePackageVersionsFromResolvedFile
KIT := Packages/LahzaKit
APP_ID := com.waleedsamouh.lahza
JOBS ?= 4
# A connected iPhone's UDID (from `make devices`), for `make device`.
DEVICE_ID ?=
# The folder holding GeoNames' cities15000.txt and admin1CodesASCII.txt, and the dump's date, for `make gazetteer`.
GEONAMES ?=
GEONAMES_DATE ?= 20261028
# The simulator the seed and photo targets act on, by UDID: the first available device named exactly $(SIM).
LPAREN := (
SIM_UDID ?= $(shell xcrun simctl list devices available | awk -v p='    $(SIM) $(LPAREN)' \
	'index($$0, p) == 1 { u = substr($$0, length(p) + 1, 36); if (u ~ /^[0-9A-F]+-[0-9A-F]+-[0-9A-F]+-[0-9A-F]+-[0-9A-F]+$$/) { print u; exit } }')
# Its photo and video files, which hold only its 6 sample photos until something is added.
SIM_MEDIA = $(HOME)/Library/Developer/CoreSimulator/Devices/$(SIM_UDID)/data/Media/DCIM
SIM_SAMPLES := 6
SEED_DIR := .build/seed

.PHONY: help project build test test-kit test-app perf-kit run devices device gazetteer seed-photos sim-reset grant-photos probe-photos verify-search screens clean

help:
	@echo 'make project   regenerate Lahza.xcodeproj from project.yml'
	@echo 'make build     build for the simulator ($(SIM))'
	@echo 'make run       build, install and launch on the simulator'
	@echo 'make test      kit tests on the Mac + app tests on the simulator'
	@echo 'make perf-kit  the opt-in performance tests (100k-asset index build), in release on the Mac'
	@echo 'make devices   list connected iPhones and their UDIDs'
	@echo 'make device DEVICE_ID=<udid>   build, sign, install and launch on your iPhone'
	@echo 'make gazetteer GEONAMES=<dir>  rebuild the offline place list from a GeoNames dump (Tools/gazetteer/README.md)'
	@echo 'make seed-photos   add the 557-item hero seed library to the simulator'"'"'s Photos (once; FORCE=1 adds it again)'
	@echo 'make grant-photos  give Lahza full photo access on the simulator'
	@echo 'make probe-photos  check what PhotoKit kept of the seed library and print its PROBE facts (seeded simulator, after grant-photos)'
	@echo 'make verify-search build the search index from the seeded simulator'"'"'s real PhotoKit and check it against the scenario'
	@echo 'make screens   screenshots of Ask'"'"'s results for the review queries, light and dark, into .build/screens (hero seed, no PhotoKit)'
	@echo 'make sim-reset CONFIRM=1   DESTRUCTIVE: erases the simulator (every app, photo and setting on it)'

project:            ## Regenerate Lahza.xcodeproj from project.yml
	xcodegen generate --spec project.yml --quiet
	@# Xcode reads package pins only from the project's own resolved file: the kit's, used as is (XCB), so the app links what `swift test` tested.
	@mkdir -p Lahza.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
	@cp $(KIT)/Package.resolved Lahza.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

build: project      ## Build the app for the simulator
	set -o pipefail && $(XCB) build | xcbeautify --quiet

test-kit:           ## Logic tests on the Mac host (fast)
	swift test --package-path $(KIT) --jobs $(JOBS)

test-app: project   ## App-hosted tests on the simulator
	set -o pipefail && $(XCB) test | xcbeautify --quiet

test: test-kit test-app

# Optimised, with DEBUG still defined: the kit tests share the DEBUG-only seed library. Adds a release build to the package's .build.
perf-kit:           ## Opt-in performance tests on the Mac, optimised
	LZ_PERF=1 swift test --package-path $(KIT) -c release -Xswiftc -DDEBUG --jobs $(JOBS) --filter Performance

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
	set -o pipefail && xcodebuild -project Lahza.xcodeproj -scheme Lahza -configuration Debug -destination 'id=$(DEVICE_ID)' -derivedDataPath $(DERIVED) -onlyUsePackageVersionsFromResolvedFile build | xcbeautify --quiet
	xcrun devicectl device install app --device $(DEVICE_ID) "$(DERIVED)/Build/Products/Debug-iphoneos/Lahza.app"
	xcrun devicectl device process launch --terminate-existing --device $(DEVICE_ID) $(APP_ID)

gazetteer:          ## Rebuild LZGeo's cities15000.lzgz from a GeoNames dump (Tools/gazetteer/README.md)
	@test -n "$(GEONAMES)" || { echo 'Set GEONAMES to the folder with cities15000.txt and admin1CodesASCII.txt'; exit 1; }
	swift run --package-path $(KIT) lz-gazetteer \
		--cities "$(GEONAMES)/cities15000.txt" --admin1 "$(GEONAMES)/admin1CodesASCII.txt" \
		--aliases Tools/gazetteer/aliases-en.tsv --source-date $(GEONAMES_DATE) \
		--out $(KIT)/Sources/LZGeo/Resources/cities15000.lzgz

seed-photos:        ## Render the hero seed library and add it to the simulator's Photos (refuses a second run without FORCE=1)
	@test -n "$(SIM_UDID)" || { echo 'No available simulator named "$(SIM)".'; exit 1; }
	@held=$$(find "$(SIM_MEDIA)" -type f ! -path '*/.*' 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$held" -gt $(SIM_SAMPLES) ] && [ "$(FORCE)" != 1 ]; then \
		echo "$(SIM) ($(SIM_UDID)) already holds $$held photos and videos (the seed library, or part of it). FORCE=1 adds the seed library again (duplicates); make sim-reset CONFIRM=1 starts clean."; \
		exit 1; fi
	rm -rf $(SEED_DIR)/hero
	swift run --package-path $(KIT) lz-seed render --scenario hero --out $(SEED_DIR)/hero
	xcrun simctl bootstatus $(SIM_UDID) -b > /dev/null
	find $(SEED_DIR)/hero/media -type f | sort | xargs -n 100 xcrun simctl addmedia $(SIM_UDID)
	@echo "Added $$(ls $(SEED_DIR)/hero/media | wc -l | tr -d ' ') seed photos and videos to $(SIM) ($(SIM_UDID)). Next: make grant-photos"
	rm -rf $(SEED_DIR)/hero/media

sim-reset:          ## ERASES the simulator: every app, photo and setting on it. Needs CONFIRM=1
	@test "$(CONFIRM)" = 1 || { echo 'sim-reset ERASES $(SIM) ($(SIM_UDID)): every app, photo and setting on it. Run: make sim-reset CONFIRM=1'; exit 1; }
	@test -n "$(SIM_UDID)" || { echo 'No available simulator named "$(SIM)".'; exit 1; }
	@echo 'Erasing $(SIM) ($(SIM_UDID))'
	xcrun simctl shutdown $(SIM_UDID) 2>/dev/null || true
	xcrun simctl erase $(SIM_UDID)

grant-photos:       ## Give Lahza full photo access on the simulator, without the prompt
	@test -n "$(SIM_UDID)" || { echo 'No available simulator named "$(SIM)".'; exit 1; }
	xcrun simctl bootstatus $(SIM_UDID) -b > /dev/null
	xcrun simctl privacy $(SIM_UDID) grant photos $(APP_ID)

probe-photos: project  ## PhotoKitProbeTests on the seeded simulator: what the import kept (SeedCapabilities), then its PROBE lines
	@mkdir -p .build
	set -o pipefail && TEST_RUNNER_LZ_SEEDED_LIBRARY=1 $(XCB) test -only-testing:LahzaTests/PhotoKitProbeTests -collect-test-diagnostics never \
		| tee .build/probe-photos.log | xcbeautify --quiet --is-ci --preserve-unbeautified | grep -v -e IDESchemeActionSDKRecord -e IDETestOperationsObserverDebug; \
		status=$$?; grep '^PROBE ' .build/probe-photos.log; exit $$status

verify-search: project grant-photos  ## SeededLibraryTests on the seeded simulator: the index of real PhotoKit, then its SEEDED lines
	@mkdir -p .build
	set -o pipefail && TEST_RUNNER_LZ_SEEDED_LIBRARY=1 $(XCB) test -only-testing:LahzaTests/SeededLibraryTests -collect-test-diagnostics never \
		| tee .build/verify-search.log | xcbeautify --quiet --is-ci --preserve-unbeautified | grep -v -e IDESchemeActionSDKRecord -e IDETestOperationsObserverDebug; \
		status=$$?; grep '^SEEDED ' .build/verify-search.log; exit $$status

screens: build      ## Ask's results for the search review queries, light and dark, from the hero seed library → .build/screens
	@test -n "$(SIM_UDID)" || { echo 'No available simulator named "$(SIM)".'; exit 1; }
	xcrun simctl bootstatus $(SIM_UDID) -b > /dev/null
	xcrun simctl install $(SIM_UDID) "$(DERIVED)/Build/Products/Debug-iphonesimulator/Lahza.app"
	Tools/screens.sh $(SIM_UDID) .build/screens $(APP_ID)

clean:
	rm -rf .build $(KIT)/.build
