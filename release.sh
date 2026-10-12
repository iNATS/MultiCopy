#!/bin/bash
# Builds the downloadable release: build/release/MultiCopy.dmg and its SHA-256 checksum.
#
#   ./release.sh
#
# Optional environment variables (in addition to build.sh's BUNDLE_ID / SIGN_IDENTITY):
#   SIGN_IDENTITY   "Developer ID Application: …"  also signs the DMG
#   NOTARY_PROFILE  notarytool keychain profile     notarizes and staples the DMG
#                   (create once: xcrun notarytool store-credentials <profile>)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MultiCopy"
OUT="build/release"
DMG="$OUT/$APP_NAME.dmg"
VENV="build/.dmgbuild-venv"

./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "build/$APP_NAME.app/Contents/Info.plist")

# dmgbuild writes the window layout directly, so no Finder scripting or permission prompts.
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    echo "→ Installing pinned dmgbuild into $VENV"
    rm -rf "$VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --disable-pip-version-check \
        --require-hashes --only-binary=:all: -r Resources/dmg/requirements.txt
fi

rm -rf "$OUT" && mkdir -p "$OUT"
echo "→ Creating $DMG"
"$VENV/bin/dmgbuild" -s Resources/dmg/settings.py \
    -D app="build/$APP_NAME.app" \
    -D icon="build/$APP_NAME.app/Contents/Resources/AppIcon.icns" \
    -D background="Resources/dmg/background.png" \
    "$APP_NAME" "$DMG"

if [ "${SIGN_IDENTITY:--}" != "-" ]; then
    echo "→ Signing DMG"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    if [ -n "${NOTARY_PROFILE:-}" ]; then
        echo "→ Notarizing (takes a few minutes)"
        xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$DMG"
    fi
fi

hdiutil verify -quiet "$DMG"
(cd "$OUT" && shasum -a 256 "$APP_NAME.dmg" > "$APP_NAME.dmg.sha256")
echo "✓ $DMG  (v$VERSION, $(du -h "$DMG" | cut -f1 | tr -d ' '))"
echo "  sha256 $(cut -d' ' -f1 "$OUT/$APP_NAME.dmg.sha256")"
