#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/DroidDock.xcodeproj"
SCHEME="DroidDock"
VERSION="${VERSION:-0.1.0}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/droiddock-release-build}"
DIST_DIR="$ROOT_DIR/dist"
APP_OUT="$DIST_DIR/DroidDock.app"
DMG_STAGING="$DIST_DIR/dmg-staging"
DMG_OUT="$DIST_DIR/DroidDock-${VERSION}-arm64.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

echo "==> Building Release DroidDock.app (arm64)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA" \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/DroidDock.app"
if [ ! -d "$BUILT_APP" ]; then
  echo "Error: Built app not found at $BUILT_APP" >&2
  exit 1
fi

rm -rf "$APP_OUT" "$DMG_STAGING" "$DMG_OUT"
mkdir -p "$DIST_DIR" "$DMG_STAGING"
ditto "$BUILT_APP" "$APP_OUT"

echo "==> Signing DroidDock.app (identity: $SIGN_IDENTITY)..."
if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --deep --sign - "$APP_OUT"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_OUT"
fi

echo "==> Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_OUT"

echo "==> Packaging DMG ($DMG_OUT)..."
ditto "$APP_OUT" "$DMG_STAGING/DroidDock.app"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create \
  -volname "DroidDock" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_OUT"
rm -rf "$DMG_STAGING"

if [ -n "${NOTARIZE_PROFILE:-}" ] && [ "$SIGN_IDENTITY" != "-" ]; then
  echo "==> Submitting DMG for notarization (profile: $NOTARIZE_PROFILE)..."
  xcrun notarytool submit "$DMG_OUT" --keychain-profile "$NOTARIZE_PROFILE" --wait
  xcrun stapler staple "$DMG_OUT"
fi

echo "==> Packaging complete:"
ls -lh "$APP_OUT" "$DMG_OUT"
