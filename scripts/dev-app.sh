#!/usr/bin/env bash
# Assemble a lightweight, runnable FocusTracker.app from the local release build
# so the real app icon shows in the Dock and Command-Tab. This is for day-to-day
# local use; the signed/notarized universal build lives in package-macos.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MACOS="$ROOT/macos"
APP="$MACOS/dist/FocusTracker.app"
CONTENTS="$APP/Contents"

echo "› Building release binary…"
( cd "$MACOS" && swift build -c release >/dev/null )
BIN="$MACOS/.build/release/FocusTracker"

echo "› Assembling app bundle…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN" "$CONTENTS/MacOS/FocusTracker"
cp "$MACOS/Resources/Info.plist" "$CONTENTS/Info.plist"

# Compile the asset-catalog PNGs into AppIcon.icns via iconutil.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cp "$MACOS/Resources/Assets.xcassets/AppIcon.appiconset/"icon_*.png "$ICONSET/"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"

echo "› Ad-hoc signing…"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Nudge Launch Services / the icon cache so the new icon is picked up.
touch "$APP"
echo "✓ Built $APP"
