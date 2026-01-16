#!/bin/bash
#
# build-release.sh
# Builds zenban for Release configuration (arm64 only) with ad-hoc code signing
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"

echo "=== Zenban Release Build ==="
echo "Project directory: $PROJECT_DIR"
echo ""

# Clean previous build
echo "Cleaning previous build..."
rm -rf "$BUILD_DIR/Release"
rm -rf "$BUILD_DIR/zenban.xcarchive"

# Build for arm64 Release
echo "Building for arm64 Release..."
xcodebuild \
    -project "$PROJECT_DIR/zenban.xcodeproj" \
    -scheme zenban \
    -configuration Release \
    -arch arm64 \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    build

# Copy the built app to build/Release
echo "Copying built app..."
mkdir -p "$BUILD_DIR/Release"
cp -R "$BUILD_DIR/DerivedData/Build/Products/Release/zenban.app" "$BUILD_DIR/Release/"

# Re-sign with ad-hoc signature (ensures all nested components are signed)
echo "Applying ad-hoc code signature..."
codesign --force --deep --sign - "$BUILD_DIR/Release/zenban.app"

# Verify the build
echo ""
echo "=== Build Verification ==="
echo "Architecture:"
file "$BUILD_DIR/Release/zenban.app/Contents/MacOS/zenban"

echo ""
echo "Code signature:"
codesign -dv "$BUILD_DIR/Release/zenban.app" 2>&1 | head -5

echo ""
echo "=== Build Complete ==="
echo "Output: $BUILD_DIR/Release/zenban.app"
