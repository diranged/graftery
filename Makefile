# Makefile for graftery
# Builds the Go CLI binary, the Swift menu-bar app, and assembles them into
# a macOS .app bundle. The CLI binary is embedded in Contents/Resources/
# and launched as a subprocess by the Swift app.

.PHONY: build build-cli build-swift build-app build-dmg generate-icon clean test test-go test-ui

APP_NAME     := Graftery
BUNDLE_ID    := com.diranged.graftery
BUILD_DIR    := build
APP_DIR      := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS_DIR := $(APP_DIR)/Contents
MACOS_DIR    := $(CONTENTS_DIR)/MacOS
RES_DIR      := $(CONTENTS_DIR)/Resources

# Default target: just build the Go CLI (fastest feedback loop during dev)
build: build-cli

# Build the standalone Go CLI binary (the runner scale set controller)
build-cli:
	go build -o $(BUILD_DIR)/graftery .

# Build the Swift macOS menu-bar app in release mode
build-swift:
	cd ConfigUI && swift build -c release
	@echo "Built Graftery (Swift)"

# Assemble the full .app bundle by combining CLI + Swift app + resources.
# Depends on the icon, CLI, and Swift builds completing first.
build-app: $(RES_DIR)/AppIcon.icns build-cli build-swift
	@mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	# Copy Swift app binary as the main executable
	cp ConfigUI/.build/release/Graftery "$(MACOS_DIR)/Graftery"
	# Embed Go CLI binary in Resources (RunnerManager looks for it here)
	cp $(BUILD_DIR)/graftery "$(RES_DIR)/graftery-cli"
	# Copy bundle metadata and optional status bar icons
	cp packaging/Info.plist "$(CONTENTS_DIR)/Info.plist"
	cp packaging/StatusBarIconTemplate.png "$(RES_DIR)/StatusBarIconTemplate.png" 2>/dev/null || true
	cp "packaging/StatusBarIconTemplate@2x.png" "$(RES_DIR)/StatusBarIconTemplate@2x.png" 2>/dev/null || true
	# Ad-hoc code sign (sufficient for local use; replace with identity for distribution)
	codesign --force --deep --sign - "$(APP_DIR)"
	@echo "Built $(APP_DIR)"

# Copy the app icon into the bundle's Resources directory
$(RES_DIR)/AppIcon.icns: packaging/AppIcon.icns
	@mkdir -p "$(RES_DIR)"
	cp packaging/AppIcon.icns "$(RES_DIR)/AppIcon.icns"

# Generate the .icns icon file from source assets if it doesn't exist
packaging/AppIcon.icns:
	./packaging/generate-icons.sh

# Build a distributable DMG disk image containing the .app
build-dmg: build-app
	./packaging/build-dmg.sh

# Remove all build artifacts
clean:
	rm -rf $(BUILD_DIR)
	cd ConfigUI && swift package clean 2>/dev/null || true

# Install the .app into /Applications (for local testing)
install: build-app
	cp -R "$(APP_DIR)" "/Applications/$(APP_NAME).app"
	@echo "Installed to /Applications/$(APP_NAME).app"

# Run all tests (Go + Swift UI tests)
test: test-go test-ui

# Run Go tests
test-go:
	go test ./...

# Run Swift UI tests (requires Xcode)
test-ui:
	cd ConfigUI && xcodegen generate
	cd ConfigUI && xcodebuild test \
		-project Graftery.xcodeproj \
		-scheme GrafteryUITests \
		-destination 'platform=macOS' \
		| grep -E "Test Case|passed|failed|TEST SUCCEEDED|TEST FAILED"

# Remove the installed app from /Applications
uninstall:
	rm -rf "/Applications/$(APP_NAME).app"
