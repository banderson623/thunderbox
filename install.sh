#!/bin/bash
# Build Thunderbox and install it into /Applications, replacing any existing copy.
# Usage: ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Thunderbox"
SRC="build/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"

echo "==> Building…"
./build-app.sh

# Quit any running instance (from build/ or /Applications) so we can replace it cleanly.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Quitting running ${APP_NAME}…"
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.2; done
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

echo "==> Installing to ${DEST}…"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
codesign --verify --strict "$DEST" >/dev/null 2>&1 && echo "    signature valid"

echo "==> Done. Launch with: open '${DEST}'"
