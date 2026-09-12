# CaneKit — CLI build / install / launch. Run from ios/.
#
#   make gen                 regenerate CaneKit.xcodeproj (scripts/gen.sh)
#   make test                pure-logic unit tests (Logic/, no device needed)
#   make build               device build with automatic signing
#   make install             install the built .app on the phone
#   make launch              launch it
#   make run                 gen + build + install + launch
#   make sim                 build for the iOS simulator (UI / nav logic only; no LiDAR, no haptics)
#   make uitest / tour       XCUITests / screenshot tour on the iPhone 17 Pro Max simulator
#   make e2e                 GPS-replay end-to-end scenarios through the real app (SCENARIO=clean …)
#   make devices             list connected devices (find DEVICE)
#
# TEAM and DEVICE come from local.mk (git-ignored):
#   TEAM   = ABCDE12345                # the OU= value of the Apple Development certificate (below)
#   DEVICE = 00008150-000A1B2C3D4E5F   # make devices
# TEAM: add the Apple ID in Xcode (Settings > Accounts), `make gen`, open CaneKit.xcodeproj once,
# CaneKit target > Signing & Capabilities > pick the Personal Team (creates the certificate). Then
# read the Team ID in Xcode > Settings > Accounts > team details, or run
#   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
# and take OU=. Not the 10 characters in parentheses of "Apple Development: Name (…)".

-include local.mk
# A comment after the value in local.mk ("DEVICE = 0000…   # make devices") leaves trailing spaces
# in the variable, and xcodebuild then cannot find the phone. Strip them.
TEAM   := $(strip $(TEAM))
DEVICE := $(strip $(DEVICE))

TEAM   ?=
DEVICE ?=
SCHEME ?= CaneKit
CONFIG ?= Debug
DERIVED = build
APP     = $(DERIVED)/Build/Products/$(CONFIG)-iphoneos/CaneKit.app
BUNDLE  = com.aritro.canekit
XCB     = xcodebuild -project CaneKit.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED)

.PHONY: gen test build install launch run sim devices clean check-env uitest tour sim17 sim-grant e2e uitest-streetview audit

gen:
	scripts/gen.sh

test:
	scripts/test.sh

check-env:
	@test -n "$(TEAM)"   || { echo "TEAM is empty — put TEAM=<10-char team id> in ios/local.mk"; exit 1; }
	@test -n "$(DEVICE)" || { echo "DEVICE is empty — run 'make devices' and put DEVICE=<id> in ios/local.mk"; exit 1; }

build: check-env
	$(XCB) -destination "platform=iOS,id=$(DEVICE)" \
	  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
	  DEVELOPMENT_TEAM=$(TEAM) CODE_SIGN_STYLE=Automatic build

install: check-env
	xcrun devicectl device install app --device $(DEVICE) $(APP)

launch: check-env
	xcrun devicectl device process launch --device $(DEVICE) $(BUNDLE)

run: gen build install launch

sim:
	$(XCB) -destination "generic/platform=iOS Simulator" CODE_SIGNING_ALLOWED=NO build

# XCUITest run in the simulator (SIM = a booted or bootable simulator name/UDID).
# The demo phone is an iPhone 17 Pro Max on iOS 27; Xcode 27 does not create that device by
# default — `make sim17` creates it once.
SIM ?= iPhone 17 Pro Max
# Pre-answer the permission prompts so no system alert races the first tap (fresh simulator / CI).
sim-grant:
	-xcrun simctl boot "$(SIM)" 2>/dev/null
	-xcrun simctl privacy "$(SIM)" grant location $(BUNDLE)
	-xcrun simctl privacy "$(SIM)" grant motion $(BUNDLE)

uitest: sim-grant
	$(XCB) -destination "platform=iOS Simulator,name=$(SIM)" CODE_SIGNING_ALLOWED=NO -only-testing:CaneKitUITests test

# "Where am I" on a real street scene: Street View frames stand in for the camera (FrameReplay).
STREETVIEW ?= scripts/streetview
# TEST_RUNNER_* must be in xcodebuild's *environment* (it strips the prefix and hands the rest to
# the test runner); written after the command it is only a build setting and never arrives.
uitest-streetview: sim-grant
	TEST_RUNNER_CANEKIT_FRAME_DIR=$(abspath $(STREETVIEW)) \
	  $(XCB) -destination "platform=iOS Simulator,name=$(SIM)" CODE_SIGNING_ALLOWED=NO \
	  -only-testing:CaneKitUITests/CaneKitUITests/testWhereAmIDescribesAStreetViewFrame test

# Screenshot tour of every screen state (CaneKitVisualTour); PNGs land in SHOTS.
SHOTS ?= $(DERIVED)/shots
tour: sim-grant
	mkdir -p $(SHOTS)
	TEST_RUNNER_CANEKIT_SHOTS=$(abspath $(SHOTS)) \
	  $(XCB) -destination "platform=iOS Simulator,name=$(SIM)" CODE_SIGNING_ALLOWED=NO \
	  -only-testing:CaneKitUITests/CaneKitVisualTour test

# End-to-end GPS replay through the real app (scripts/e2e.py): clean, missed_fence, gps_jitter,
# wrong_turn (SCENARIO=all). SCENARIO=streetview reruns clean with Street View frames as the
# camera (needs the local-only JPEGs). Asserts on the app's JSONL trip log; report + logs in
# build/e2e/. ~20 min for all. Always muted (CANEKIT_MUTE).
SCENARIO ?= all
e2e: sim sim-grant
	python3 scripts/e2e.py --sim "$(SIM)" --scenario $(SCENARIO)

# Cue load of one walk (scripts/cue_audit.py, Step 35): mounted or handheld, head band wall vs
# overhang, cues and spoken lines per minute, replays. LOG=path, or no LOG to pull the newest trip
# log off the phone in local.mk. Read-only; no simulator.
audit:
	python3 scripts/cue_audit.py --selftest
	python3 scripts/cue_audit.py $(if $(LOG),"$(LOG)",--pull)

sim17:
	xcrun simctl create "iPhone 17 Pro Max" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-27-0

devices:
	xcrun devicectl list devices

clean:
	rm -rf $(DERIVED) CaneKit.xcodeproj Logic/.build
