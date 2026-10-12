#!/bin/bash
# Builds MultiCopy.app as a universal (Apple silicon + Intel) app for macOS 12+.
#
#   ./build.sh              build into ./build
#   ./build.sh install      build, copy to /Applications and launch
#
# Optional environment variables:
#   BUNDLE_ID      bundle identifier            (default: com.mohamedaref.multicopy)
#   SIGN_IDENTITY  codesigning identity         (default: "-" = ad-hoc, fine for this Mac)
#                  e.g. "Developer ID Application: Your Name (TEAMID)" for distribution
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MultiCopy"
VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_MACOS="12.0"
BUNDLE_ID="${BUNDLE_ID:-com.mohamedaref.multicopy}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/obj"

for ARCH in arm64 x86_64; do
    echo "→ Compiling $ARCH"
    xcrun swiftc Sources/*.swift \
        -target "$ARCH-apple-macos$MIN_MACOS" \
        -sdk "$SDK" \
        -swift-version 5 \
        -O -whole-module-optimization \
        -Xlinker -dead_strip \
        -o "$BUILD_DIR/obj/$APP_NAME-$ARCH"
done

lipo -create "$BUILD_DIR/obj/$APP_NAME-arm64" "$BUILD_DIR/obj/$APP_NAME-x86_64" \
     -output "$APP/Contents/MacOS/$APP_NAME"
strip -x "$APP/Contents/MacOS/$APP_NAME"

sed -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    -e "s/__VERSION__/$VERSION/" \
    -e "s/__BUILD__/$BUILD_NUMBER/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "→ App icon"
ICONSET="$BUILD_DIR/obj/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
    sips -z $SIZE $SIZE Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    sips -z $((SIZE * 2)) $((SIZE * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "→ Signing ($SIGN_IDENTITY) with hardened runtime"
TIMESTAMP="--timestamp=none"
[ "$SIGN_IDENTITY" != "-" ] && TIMESTAMP="--timestamp"
codesign --force --options runtime $TIMESTAMP --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=1 "$APP"

ditto -c -k --keepParent "$APP" "$BUILD_DIR/$APP_NAME.zip"
echo "✓ Built $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"

if [ "${1:-}" = "install" ]; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    rm -rf "/Applications/$APP_NAME.app"
    ditto "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    echo "✓ Installed to /Applications and launched"
fi
