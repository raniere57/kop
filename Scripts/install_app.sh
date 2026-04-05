#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/Kop.app"
TARGET_PATH="/Applications/Kop.app"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App not found at $APP_PATH" >&2
  echo "Run ./Scripts/create_dmg.sh first to build the Release app into dist/." >&2
  exit 1
fi

echo "Installing Kop to /Applications..."
rm -rf "$TARGET_PATH"
ditto "$APP_PATH" "$TARGET_PATH"

echo "Registering with Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f "$TARGET_PATH"

echo "Refreshing Spotlight metadata..."
mdimport "$TARGET_PATH" || true

echo "Rebuilding Launch Services registration..."
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -kill -r -domain local -domain system -domain user || true

echo "Resetting Launchpad and restarting Dock..."
defaults write com.apple.dock ResetLaunchPad -bool true || true
killall Dock || true

echo "Opening app once..."
open "$TARGET_PATH" || true

echo
echo "Installed at:"
echo "  $TARGET_PATH"
