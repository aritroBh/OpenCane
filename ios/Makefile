# CaneKit — CLI build / install / launch. Run from ios/.
#
#   make gen                 regenerate CaneKit.xcodeproj (scripts/gen.sh)
#   make test                pure-logic unit tests (Logic/, no device needed)
#   make build               device build with automatic signing
#   make install             install the built .app on the phone
#   make launch              launch it
#   make run                 gen + build + install + launch
#   make sim                 build for the iOS simulator (UI / nav logic only; no LiDAR, no haptics)
#   make devices             list connected devices (find DEVICE)
#
# TEAM and DEVICE come from local.mk (git-ignored):
#   TEAM   = ABCDE12345                # security find-identity -v -p codesigning
#   DEVICE = 00008150-000A1B2C3D4E5F   # make devices

-include local.mk

TEAM   ?=
DEVICE ?=
SCHEME ?= CaneKit
CONFIG ?= Debug
DERIVED = build
APP     = $(DERIVED)/Build/Products/$(CONFIG)-iphoneos/CaneKit.app
BUNDLE  = com.aritro.canekit
XCB     = xcodebuild -project CaneKit.xcodeproj -scheme $(SCHEME) -configuration $(CONFIG) -derivedDataPath $(DERIVED)

.PHONY: gen test build install launch run sim devices clean check-env uitest tour sim17 sim-grant

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

# Screenshot tour of every screen state (CaneKitVisualTour); PNGs land in SHOTS.
SHOTS ?= $(DERIVED)/shots
tour: sim-grant
	mkdir -p $(SHOTS)
	$(XCB) -destination "platform=iOS Simulator,name=$(SIM)" CODE_SIGNING_ALLOWED=NO \
	  -only-testing:CaneKitUITests/CaneKitVisualTour TEST_RUNNER_CANEKIT_SHOTS=$(abspath $(SHOTS)) test

sim17:
	xcrun simctl create "iPhone 17 Pro Max" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-27-0

devices:
	xcrun devicectl list devices

clean:
	rm -rf $(DERIVED) CaneKit.xcodeproj Logic/.build
