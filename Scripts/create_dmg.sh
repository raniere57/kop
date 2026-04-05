#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT_DIR/Kop.xcodeproj"
SCHEME="Kop"
DERIVED_DATA="$ROOT_DIR/.derived"
DIST_DIR="$ROOT_DIR/dist"
STAGING_DIR="$DIST_DIR/dmg"
APP_PATH="$DERIVED_DATA/Build/Products/Release/Kop.app"
DIST_APP_PATH="$DIST_DIR/Kop.app"
DMG_PATH="$DIST_DIR/Kop.dmg"
VOL_NAME="Kop"

mkdir -p "$DIST_DIR"
rm -rf "$STAGING_DIR" "$DMG_PATH" "$DIST_APP_PATH"

echo "Building Release app..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  build

if [[ ! -d "$APP_PATH" ]]; then
  echo "Release app not found at: $APP_PATH" >&2
  exit 1
fi

cp -R "$APP_PATH" "$DIST_APP_PATH"

mkdir -p "$STAGING_DIR"
cp -R "$DIST_APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

echo "Creating DMG..."
if ! hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"; then
  echo >&2
  echo "Failed to create DMG with hdiutil." >&2
  echo "The Release app is available at:" >&2
  echo "  $DIST_APP_PATH" >&2
  echo "If you are running inside a restricted environment, run this script directly on your macOS session." >&2
  exit 1
fi

rm -rf "$STAGING_DIR"

echo
echo "DMG created at:"
echo "  $DMG_PATH"

echo
echo "Opening DMG..."
open "$DMG_PATH"
