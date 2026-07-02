APP_NAME := BirdMenu
APP_BUNDLE_ID := st.rio.birdmenu
APP_VERSION := 1.1.3
APP_BUILD := 7
BUILD_DIR := .build/release
APP_DIR := build/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
RESOURCES_DIR := $(CONTENTS_DIR)/Resources
STAGING_DIR := /tmp/$(APP_NAME)-app-build
STAGING_APP_DIR := $(STAGING_DIR)/$(APP_NAME).app
STAGING_CONTENTS_DIR := $(STAGING_APP_DIR)/Contents
STAGING_MACOS_DIR := $(STAGING_CONTENTS_DIR)/MacOS
STAGING_RESOURCES_DIR := $(STAGING_CONTENTS_DIR)/Resources
SCRUB_XATTRS := xattr -dr com.apple.provenance "$(STAGING_APP_DIR)" 2>/dev/null || true; \
	xattr -dr com.apple.macl "$(STAGING_APP_DIR)" 2>/dev/null || true; \
	xattr -dr com.apple.FinderInfo "$(STAGING_APP_DIR)" 2>/dev/null || true; \
	xattr -dr "com.apple.fileprovider.fpfs\#P" "$(STAGING_APP_DIR)" 2>/dev/null || true; \
	xattr -cr "$(STAGING_APP_DIR)"
SCRUB_APP_XATTRS := xattr -dr com.apple.provenance "$(APP_DIR)" 2>/dev/null || true; \
	xattr -dr com.apple.macl "$(APP_DIR)" 2>/dev/null || true; \
	xattr -dr com.apple.FinderInfo "$(APP_DIR)" 2>/dev/null || true; \
	xattr -dr "com.apple.fileprovider.fpfs\#P" "$(APP_DIR)" 2>/dev/null || true; \
	xattr -cr "$(APP_DIR)"

.PHONY: build test app run clean

build:
	swift build -c release

test:
	swift test
	node Tools/test-analyze-btsnoop.js

app: build
	rm -rf "$(APP_DIR)"
	rm -rf "$(STAGING_DIR)"
	mkdir -p "$(STAGING_MACOS_DIR)" "$(STAGING_RESOURCES_DIR)"
	cp "$(BUILD_DIR)/$(APP_NAME)" "$(STAGING_MACOS_DIR)/$(APP_NAME)"
	cp Resources/Info.plist "$(STAGING_CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleDevelopmentRegion -string en "$(STAGING_CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleExecutable -string "$(APP_NAME)" "$(STAGING_CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleIdentifier -string "$(APP_BUNDLE_ID)" "$(STAGING_CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleName -string "$(APP_NAME)" "$(STAGING_CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleShortVersionString -string "$(APP_VERSION)" "$(STAGING_CONTENTS_DIR)/Info.plist"
	plutil -replace CFBundleVersion -string "$(APP_BUILD)" "$(STAGING_CONTENTS_DIR)/Info.plist"
	cp Resources/BirdMenu.icns "$(STAGING_RESOURCES_DIR)/BirdMenu.icns"
	$(SCRUB_XATTRS)
	codesign --force --sign - "$(STAGING_APP_DIR)"
	$(SCRUB_XATTRS)
	mkdir -p build
	ditto --noextattr --norsrc "$(STAGING_APP_DIR)" "$(APP_DIR)"
	$(SCRUB_APP_XATTRS)
	codesign --force --sign - "$(APP_DIR)"
	$(SCRUB_APP_XATTRS)
	@echo "$(APP_DIR)"

run: app
	open "$(APP_DIR)"

clean:
	rm -rf .build build
