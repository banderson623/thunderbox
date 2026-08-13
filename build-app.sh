#!/bin/bash
# Build Thunderbox.app — a self-contained macOS app bundle.
# Usage: ./build-app.sh
# The app icon is rendered per-size by assets/gen-icon.swift. To use a hand-made
# 1024×1024 icon instead: ICON_PNG=path/to/icon.png ./build-app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Thunderbox"
BUNDLE_ID="com.thunderbox.app"
BUILD_DIR=".build/release"
APP="build/${APP_NAME}.app"
CONTENTS="${APP}/Contents"

echo "==> Compiling (release)…"
swift build -c release

echo "==> Rendering icon…"
ICONSET="build/${APP_NAME}.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
if [ -n "${ICON_PNG:-}" ] && [ -f "${ICON_PNG}" ]; then
  # Escape hatch: ICON_PNG=path/to/1024.png downscales a hand-made icon instead.
  echo "    downscaling ${ICON_PNG}"
  for sz in 16 32 64 128 256 512; do
    sips -z $sz $sz "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
    d=$((sz*2))
    sips -z $d $d "$ICON_PNG" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
  done
else
  # Render each size natively — small sizes get a simplified design that stays
  # legible (see assets/gen-icon.swift) instead of a downscaled blur.
  swift assets/gen-icon.swift --iconset "$ICONSET" | sed 's/^/    /'
fi
iconutil -c icns "$ICONSET" -o "build/${APP_NAME}.icns"

echo "==> Assembling bundle…"
rm -rf "$APP"
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"
cp "${BUILD_DIR}/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"
cp "build/${APP_NAME}.icns" "${CONTENTS}/Resources/${APP_NAME}.icns"

cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIconFile</key><string>${APP_NAME}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "APPL????" > "${CONTENTS}/PkgInfo"

# --- Code signing -----------------------------------------------------------
# Identity selection order:
#   1. $SIGN_IDENTITY if set (e.g. a full "Developer ID Application: …" string)
#   2. a "Developer ID Application" cert in the keychain (needed for notarized
#      distribution outside the App Store)
#   3. an "Apple Development" cert (signs it properly for THIS Mac / registered
#      devices — not accepted by Gatekeeper on other machines)
#   4. ad-hoc ("-") — the fallback for CI where no identity is installed
if [ -n "${SIGN_IDENTITY:-}" ]; then
  IDENTITY="$SIGN_IDENTITY"
else
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/{print $2; exit}')
  [ -z "$IDENTITY" ] && IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/{print $2; exit}')
  [ -z "$IDENTITY" ] && IDENTITY="-"
fi

# Hardened runtime only makes sense (and is required) for a Developer ID build
# destined for notarization; skip it for dev/ad-hoc signing.
SIGN_OPTS=(--force --deep --sign "$IDENTITY")
case "$IDENTITY" in
  "Developer ID Application"*) SIGN_OPTS+=(--options runtime --timestamp) ;;
esac

echo "==> Signing with: ${IDENTITY}"
codesign "${SIGN_OPTS[@]}" "$APP" 2>&1 | sed 's/^/    /' || \
  echo "    (codesign failed — leaving unsigned)"

echo "==> Done: ${APP}"
echo "    Open with: open '${APP}'"
