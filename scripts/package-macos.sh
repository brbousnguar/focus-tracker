#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MACOS_DIR="$ROOT_DIR/macos"
DIST_DIR="$MACOS_DIR/dist"
APP_PATH="$DIST_DIR/FocusTracker.app"
DMG_PATH="$DIST_DIR/FocusTracker.dmg"
STAGING_DIR="$DIST_DIR/dmg"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:--}"
MODULE_CACHE_DIR="$MACOS_DIR/.build/module-cache"

# Keep compiler caches inside the project so packaging works in clean CI and
# restricted development environments without relying on user-level caches.
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "VERSION must look like 1.2.3 (received: $VERSION)" >&2
    exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "BUILD_NUMBER must be a positive integer (received: $BUILD_NUMBER)" >&2
    exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p \
    "$APP_PATH/Contents/MacOS" \
    "$APP_PATH/Contents/Resources" \
    "$STAGING_DIR" \
    "$MODULE_CACHE_DIR"

echo "Building FocusTracker for Apple silicon..."
swift build \
    --package-path "$MACOS_DIR" \
    --configuration release \
    --triple arm64-apple-macosx13.0 \
    --scratch-path "$MACOS_DIR/.build/release-arm64"

echo "Building FocusTracker for Intel..."
swift build \
    --package-path "$MACOS_DIR" \
    --configuration release \
    --triple x86_64-apple-macosx13.0 \
    --scratch-path "$MACOS_DIR/.build/release-x86_64"

echo "Creating universal executable..."
lipo -create \
    "$MACOS_DIR/.build/release-arm64/arm64-apple-macosx/release/FocusTracker" \
    "$MACOS_DIR/.build/release-x86_64/x86_64-apple-macosx/release/FocusTracker" \
    -output "$APP_PATH/Contents/MacOS/FocusTracker"
chmod +x "$APP_PATH/Contents/MacOS/FocusTracker"

cp "$MACOS_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"

echo "Compiling the app icon..."
xcrun actool "$MACOS_DIR/Resources/Assets.xcassets" \
    --compile "$APP_PATH/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$DIST_DIR/asset-info.plist"
rm -f "$DIST_DIR/asset-info.plist"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Ad-hoc signing the development package..."
    codesign --force --deep --sign - "$APP_PATH"
else
    echo "Signing with Developer ID: $SIGNING_IDENTITY"
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$SIGNING_IDENTITY" \
        "$APP_PATH"
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Creating the installer disk image..."
ditto "$APP_PATH" "$STAGING_DIR/FocusTracker.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
    -volname "FocusTracker" \
    -srcfolder "$STAGING_DIR" \
    -format UDZO \
    -ov \
    "$DMG_PATH"

if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
fi

rm -rf "$STAGING_DIR"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

echo
echo "Created: $DMG_PATH"
echo "Architectures: $(lipo -archs "$APP_PATH/Contents/MacOS/FocusTracker")"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "This is an ad-hoc signed development build. Do not publish it as a trusted release."
else
    echo "The DMG is Developer ID signed and ready for notarization."
fi
