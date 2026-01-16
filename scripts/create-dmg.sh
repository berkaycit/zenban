#!/bin/bash
#
# create-dmg.sh
# Creates a DMG file for Zenban distribution
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
APP_PATH="$BUILD_DIR/Release/zenban.app"
DMG_NAME="Zenban-1.0"
DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"
TEMP_DIR="$BUILD_DIR/dmg-temp"

echo "=== Zenban DMG Creator ==="
echo ""

# Check if the app exists
if [ ! -d "$APP_PATH" ]; then
    echo "Error: zenban.app not found at $APP_PATH"
    echo "Please run ./scripts/build-release.sh first"
    exit 1
fi

# Clean up any previous DMG artifacts
echo "Cleaning previous DMG artifacts..."
rm -rf "$TEMP_DIR"
rm -f "$DMG_PATH"

# Create temporary directory structure
echo "Creating DMG contents..."
mkdir -p "$TEMP_DIR"

# Copy the app
cp -R "$APP_PATH" "$TEMP_DIR/"

# Create symlink to Applications folder
ln -s /Applications "$TEMP_DIR/Applications"

# Create the DMG
echo "Creating DMG file..."
hdiutil create \
    -volname "Zenban" \
    -srcfolder "$TEMP_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# Clean up
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

# Verify the DMG
echo ""
echo "=== DMG Verification ==="
echo "DMG file:"
ls -lh "$DMG_PATH"

echo ""
echo "DMG contents:"
hdiutil attach "$DMG_PATH" -mountpoint /tmp/zenban-verify -nobrowse -quiet
ls -la /tmp/zenban-verify/
hdiutil detach /tmp/zenban-verify -quiet

echo ""
echo "=== DMG Created Successfully ==="
echo "Output: $DMG_PATH"
echo ""
echo "Installation instructions:"
echo "1. Open the DMG file"
echo "2. Drag zenban.app to Applications"
echo "3. On first launch: Right-click > Open (to bypass Gatekeeper)"
echo "4. Click 'Open' in the dialog"
