#!/bin/bash
# Build Thunderbox.app — a self-contained macOS app bundle.
# Usage: ./build-app.sh
# If assets/icon.png exists (drop the real icon there, 1024×1024), it is used;
# otherwise a placeholder is generated.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Thunderbox"
BUNDLE_ID="com.thunderbox.app"
BUILD_DIR=".build/release"
APP="build/${APP_NAME}.app"
CONTENTS="${APP}/Contents"

echo "==> Compiling (release)…"
swift build -c release

echo "==> Preparing icon…"
mkdir -p assets
# Prefer icon-day.png, then an existing assets/icon.png, else a generated placeholder.
if [ -f icon-day.png ]; then
  echo "    using ./icon-day.png"
  cp icon-day.png assets/icon.png
elif [ ! -f assets/icon.png ]; then
  echo "    no icon — generating placeholder"
  swift assets/gen-icon.swift assets/icon.png
fi

ICONSET="build/${APP_NAME}.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for sz in 16 32 64 128 256 512; do
  sips -z $sz $sz assets/icon.png --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
  d=$((sz*2))
  sips -z $d $d assets/icon.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
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

# Ad-hoc sign so macOS will run it locally without Gatekeeper complaints.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "==> Done: ${APP}"
echo "    Open with: open '${APP}'"
