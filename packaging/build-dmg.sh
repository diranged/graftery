#!/bin/bash
# Creates a drag-and-drop DMG installer for Graftery.
#
# Downloads create-dmg (pinned to a specific SHA) into a local bin directory
# and uses it to produce a polished DMG with background image, icon
# positioning, and an Applications symlink.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
BIN_DIR="$BUILD_DIR/bin"
APP_PATH="$BUILD_DIR/Graftery.app"
DMG_PATH="$BUILD_DIR/Graftery.dmg"

# Pinned version of create-dmg (https://github.com/create-dmg/create-dmg)
CREATE_DMG_VERSION="v1.2.3"
CREATE_DMG_SHA="994a036532d3ac1bb1cd5a425a0d5d796ecbed83"
CREATE_DMG="$BIN_DIR/create-dmg"

if [ ! -d "$APP_PATH" ]; then
    echo "Error: $APP_PATH not found. Run 'make build-app' first."
    exit 1
fi

# Download create-dmg if not already present. We download the full tarball
# (not just the script) because create-dmg requires its support/ directory
# for AppleScript-based icon positioning.
CREATE_DMG_DIR="$BIN_DIR/create-dmg-${CREATE_DMG_VERSION}"
CREATE_DMG="$CREATE_DMG_DIR/create-dmg"

if [ ! -x "$CREATE_DMG" ]; then
    echo "Downloading create-dmg ${CREATE_DMG_VERSION} (${CREATE_DMG_SHA})..."
    mkdir -p "$BIN_DIR"
    curl -sL "https://github.com/create-dmg/create-dmg/archive/${CREATE_DMG_SHA}.tar.gz" \
        | tar xz -C "$BIN_DIR"
    mv "$BIN_DIR/create-dmg-${CREATE_DMG_SHA}" "$CREATE_DMG_DIR"
fi

rm -f "$DMG_PATH"

# Stage the app for DMG creation.
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"

echo "Building DMG..."
"$CREATE_DMG" \
    --volname "Graftery" \
    --background "$SCRIPT_DIR/dmg-background.png" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --text-size 14 \
    --icon "Graftery.app" 175 190 \
    --app-drop-link 425 190 \
    --hide-extension "Graftery.app" \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGING_DIR/"

rm -rf "$STAGING_DIR"

echo ""
echo "Created $DMG_PATH"
ls -lh "$DMG_PATH"
