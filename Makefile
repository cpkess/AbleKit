# AbleKit — everything you need from a terminal. Xcode not required.
#
#   make run      build, install to /Applications, launch
#   make dmg      build a signed installable disk image
#   make release VERSION=0.1.0
#
# Run `make` on its own for the full list.

SHELL := /bin/bash
.DEFAULT_GOAL := help

PROJECT      := AbleKit.xcodeproj
SCHEME       := AbleKit
BUNDLE_ID    := com.ablekit.AbleKit
DERIVED      := .build/dd
SPM_CACHE    := .build/spm
INSTALL_DIR  := /Applications
INSTALLED    := $(INSTALL_DIR)/AbleKit.app
DIST         := dist

# Signing. Override on the command line for a different team or identity:
#   make run DEVELOPMENT_TEAM=ABCDE12345
DEVELOPMENT_TEAM ?= WZJ4ZPRH72
RELEASE_IDENTITY ?= Developer ID Application: Gamergrams LLC (WZJ4ZPRH72)

XCB := xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
       -destination 'platform=macOS,arch=arm64' \
       -clonedSourcePackagesDirPath $(SPM_CACHE) -derivedDataPath $(DERIVED) \
       -allowProvisioningUpdates -quiet

DEBUG_APP   := $(DERIVED)/Build/Products/Debug/AbleKit.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/AbleKit.app

.PHONY: help
help:
	@echo "AbleKit"
	@echo ""
	@echo "  Developing"
	@echo "    make run                 Build, install to $(INSTALL_DIR), and launch"
	@echo "    make restart             Same, but quit the running copy first"
	@echo "    make stop                Quit AbleKit"
	@echo "    make build               Build only (Debug)"
	@echo "    make logs                Stream AbleKit's log output"
	@echo "    make status              Signing, install state, permissions, update configuration"
	@echo ""
	@echo "  Driving the running app"
	@echo "    make palette | settings | setup   Open that window"
	@echo "    make ask GOAL=\"...\"          Give AbleKit a task and follow it (Debug builds)"
	@echo "    make stop-task           Stop the running task"
	@echo "    make check-updates       Ask the running app to check for updates now"
	@echo "    make diagnostics-on      Include goals and control names in logs (off by default)"
	@echo "    make test-cloud          Check whether Private Cloud Compute is usable"
	@echo "    make reasoning-cloud     Opt in to Private Cloud Compute (reasoning-device to undo)"
	@echo ""
	@echo "  Testing"
	@echo "    make test                Core tests (fast, no permissions needed)"
	@echo "    make test-live           Also exercise the real Apple Intelligence model"
	@echo "    make eval                Real tasks on this Mac, checked independently (hands off!)"
	@echo ""
	@echo "  Permissions"
	@echo "    make permissions         Open the Accessibility pane (required)"
	@echo "    make screen-permission   Open the Screen Recording pane (optional)"
	@echo "    make reset-permissions   Clear AbleKit's grants and start over"
	@echo ""
	@echo "  Shipping"
	@echo "    make sparkle-keys        Create the update signing key (once, ever)"
	@echo "    make dmg                 Signed DMG in $(DIST)/ (not notarised)"
	@echo "    make notarize            Notarise and staple that DMG"
	@echo "    make release VERSION=x.y.z   DMG + appcast, ready to publish"
	@echo "    make publish VERSION=x.y.z   Upload it to GitHub Releases"
	@echo ""
	@echo "    make clean"

# ---------------------------------------------------------------- developing

.PHONY: build
build:
	@echo "==> Building (Debug)"
	@# The build number is the commit count, as in releases. Left at 1, a development build looked
	@# older than every release, and Sparkle offered to "update" it to an older version.
	@$(XCB) -configuration Debug DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) \
	    CURRENT_PROJECT_VERSION=$(BUILD) build

.PHONY: run
run: build stop
	@echo "==> Installing to $(INSTALLED)"
	@rm -rf "$(INSTALLED)"
	@cp -R "$(DEBUG_APP)" "$(INSTALLED)"
	@echo "==> Launching"
	@open "$(INSTALLED)"
	@echo ""
	@echo "    AbleKit is in the menu bar. Press Control-Option-Space for the palette."
	@echo "    Run 'make logs' in another tab to watch what it does."

.PHONY: restart
restart: stop run

.PHONY: stop
stop:
	@osascript -e 'tell application "AbleKit" to quit' 2>/dev/null || true
	@pkill -f "AbleKit.app/Contents/MacOS/AbleKit" 2>/dev/null || true
	@sleep 1

.PHONY: logs
logs:
	@echo "==> Streaming AbleKit logs (Control-C to stop)"
	@log stream --style compact --predicate 'subsystem == "$(BUNDLE_ID)"' --level info

.PHONY: status
status:
	@scripts/status.sh
	@echo ""
	@echo "Running app"
	@scripts/command.sh status
	@sleep 1
	@/usr/bin/log show --last 5s --style compact \
	    --predicate 'subsystem == "$(BUNDLE_ID)" AND eventMessage BEGINSWITH "Status:"' \
	    | sed -n 's/.*Status: //p' | tr ' ' '\n' | sed 's/^/  /;s/=/  /'

# ------------------------------------------------------------ driving the app

.PHONY: palette settings setup stop-task check-updates
check-updates:
	@scripts/command.sh check-updates
palette:
	@scripts/command.sh palette
settings:
	@scripts/command.sh settings
setup:
	@scripts/command.sh setup
stop-task:
	@scripts/command.sh stop

# make ask GOAL="Open System Settings"   (Debug builds only)
# make plan GOAL="..."     Plan one step for the current screen and print it, without acting
.PHONY: plan
plan:
	@test -n "$(GOAL)" || { echo 'usage: make plan GOAL="..."'; exit 1; }
	@scripts/command.sh plan "$(GOAL)"
	@sleep 6
	@/usr/bin/log show --last 10s --style compact --predicate 'subsystem == "$(BUNDLE_ID)" AND eventMessage BEGINSWITH "PLAN"' \
	    | sed 's/^.*\[com\.ablekit\.AbleKit:[A-Za-z]*\] //' | tail -1

# make prompt GOAL="..."   Show what the model is shown for the current screen (Debug builds)
.PHONY: prompt
prompt:
	@test -n "$(GOAL)" || { echo 'usage: make prompt GOAL="..."'; exit 1; }
	@scripts/command.sh prompt "$(GOAL)"
	@sleep 2
	@cat /tmp/ablekit-prompt.txt

.PHONY: ask
ask:
	@test -n "$(GOAL)" || { echo 'usage: make ask GOAL="Open System Settings"'; exit 1; }
	@scripts/ask.sh "$(GOAL)"

# Private Cloud Compute. test-cloud sends a made-up request only.
.PHONY: test-cloud reasoning-cloud reasoning-device
test-cloud:
	@scripts/command.sh test-cloud; sleep 5
	@/usr/bin/log show --last 8s --style compact \
	    --predicate 'subsystem == "$(BUNDLE_ID)" AND eventMessage BEGINSWITH "Private Cloud Compute test"' \
	    | sed -n 's/.*\] //p'
reasoning-cloud:
	@scripts/command.sh reasoning cloud && echo "==> Reasoning: Private Cloud Compute when available (Debug builds)"
reasoning-device:
	@scripts/command.sh reasoning device && echo "==> Reasoning: on this Mac"

.PHONY: diagnostics-on diagnostics-off
diagnostics-on:
	@scripts/command.sh diagnostics on && echo "==> Diagnostic logging on: goals and control names appear in logs"
diagnostics-off:
	@scripts/command.sh diagnostics off && echo "==> Diagnostic logging off"

# ------------------------------------------------------------------ testing

.PHONY: test
test:
	@swift test --package-path AbleKitCore

.PHONY: test-live
test-live:
	@ABLEKIT_LIVE_MODEL_TESTS=1 swift test --package-path AbleKitCore

# Real tasks on this Mac, checked independently. Takes over the keyboard and pointer.
#   make eval                 all tasks
#   make eval TASKS="open_calculator textedit_type"
.PHONY: eval
eval:
	@scripts/eval.sh $(TASKS)

# -------------------------------------------------------------- permissions

# System Settings is a single window, so opening two panes in a row just shows the second one.
# Each gets its own target instead.
.PHONY: permissions
permissions:
	@echo "==> Opening Accessibility. Switch AbleKit on."
	@open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

.PHONY: screen-permission
screen-permission:
	@echo "==> Opening Screen Recording. Switch AbleKit on, then run 'make restart'."
	@open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

.PHONY: reset-permissions
reset-permissions: stop
	@tccutil reset Accessibility $(BUNDLE_ID) || true
	@tccutil reset ScreenCapture $(BUNDLE_ID) || true
	@echo "==> Cleared. Run 'make run' and grant once more."

# ----------------------------------------------------------------- shipping

.PHONY: sparkle-keys
sparkle-keys:
	@scripts/generate-keys.sh

VERSION ?= $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
             "$(RELEASE_APP)/Contents/Info.plist" 2>/dev/null || echo 0.1.0)
BUILD   ?= $(shell git rev-list --count HEAD)

.PHONY: release-build
release-build:
	@echo "==> Building (Release) $(VERSION) ($(BUILD))"
	@$(XCB) -configuration Release \
	    MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD) \
	    CODE_SIGN_IDENTITY="$(RELEASE_IDENTITY)" CODE_SIGN_STYLE=Manual \
	    DEVELOPMENT_TEAM=$(DEVELOPMENT_TEAM) build

.PHONY: dmg
dmg: release-build
	@scripts/sign-app.sh "$(RELEASE_APP)" "$(RELEASE_IDENTITY)"
	@scripts/build-dmg.sh "$(RELEASE_APP)" "$(VERSION)" "$(DIST)"
	@scripts/sign-app.sh "$(DIST)/AbleKit-$(VERSION).dmg" "$(RELEASE_IDENTITY)"
	@echo ""
	@echo "    $(DIST)/AbleKit-$(VERSION).dmg is signed but NOT notarised."
	@echo "    Gatekeeper will refuse it on any other Mac until 'make notarize' runs."

.PHONY: notarize
notarize:
	@scripts/notarize.sh "$(DIST)/AbleKit-$(VERSION).dmg"

.PHONY: release
release: dmg notarize appcast
	@echo ""
	@echo "==> Ready to publish:"
	@ls -lh $(DIST)/AbleKit-$(VERSION).dmg $(DIST)/appcast.xml

.PHONY: appcast
appcast:
	@scripts/release-notes.sh "$(VERSION)" > $(DIST)/notes.txt
	@SPM_CACHE_DIR=$(SPM_CACHE) scripts/generate-appcast.sh \
	    "$(DIST)/AbleKit-$(VERSION).dmg" "$(VERSION)" "$(BUILD)" \
	    "$(DIST)/notes.txt" "$(DIST)/appcast.xml"

.PHONY: publish
publish:
	@scripts/publish.sh "$(VERSION)" "$(DIST)"

.PHONY: clean
clean: stop
	@rm -rf $(DERIVED) $(DIST)
	@swift package --package-path AbleKitCore clean 2>/dev/null || true
	@echo "==> Cleaned"
