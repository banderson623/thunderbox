#!/bin/bash
# Build Thunderbox.app and package it into a distributable, drag-to-install disk image.
# Usage: ./make-dmg.sh   ->  build/Thunderbox.dmg
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Thunderbox"
APP="build/${APP_NAME}.app"
DMG="build/${APP_NAME}.dmg"
STAGE="build/dmg-stage"

echo "==> Building app…"
./build-app.sh

echo "==> Staging disk image…"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

echo "==> Creating ${DMG}…"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

rm -rf "$STAGE"
echo "==> Done: ${DMG}"
