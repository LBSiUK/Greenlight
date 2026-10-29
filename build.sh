#!/bin/bash
# Builds a Release copy of Greenlight, installs it to /Applications and opens it. When the installed
# app opens it links the `greenlight` command into ~/.local/bin and installs the Claude Code skill.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet
xcodebuild -project Greenlight.xcodeproj -scheme Greenlight -configuration Release \
  -derivedDataPath build/DerivedData build | grep -E "error|warning: |BUILD" || true
APP="build/DerivedData/Build/Products/Release/Greenlight.app"
[ -d "$APP" ] || { echo "Build failed"; exit 1; }

pkill -x Greenlight 2>/dev/null || true
rm -rf "/Applications/Greenlight.app"
cp -R "$APP" /Applications/
# Keep the build copy out of Launchpad and Spotlight so only the installed app shows up.
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" -u "$APP" 2>/dev/null || true

open "/Applications/Greenlight.app"
echo "Installed to /Applications/Greenlight.app"
