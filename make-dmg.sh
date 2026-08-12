#!/bin/bash
# Build Thunderbox.app and package it into a distributable, drag-to-install disk image.
# If Developer ID signing + notarization credentials are available the DMG is also
# notarized and stapled; otherwise those steps are skipped (the DMG is still produced).
#
# Notarization credentials (any one of):
#   NOTARY_PROFILE                          a `xcrun notarytool store-credentials` profile
#   NOTARY_APPLE_ID + NOTARY_PASSWORD + NOTARY_TEAM_ID   (app-specific password)
#
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
hdiutil detach "/Volumes/${APP_NAME}" >/dev/null 2>&1 || true   # clear any stale mount
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null
rm -rf "$STAGE"

# --- Notarize + staple (only when credentials are provided) -----------------
notarize_submit() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  elif [ -n "${NOTARY_APPLE_ID:-}" ] && [ -n "${NOTARY_PASSWORD:-}" ] && [ -n "${NOTARY_TEAM_ID:-}" ]; then
    xcrun notarytool submit "$DMG" \
      --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" --wait
  else
    return 1
  fi
}

# Only worth notarizing a Developer-ID-signed app; check what the app was signed with.
SIGNED_BY=$(codesign -dvv "$APP" 2>&1 | awk -F'Authority=' '/Authority=/{print $2; exit}')
if [ -z "${NOTARY_PROFILE:-}${NOTARY_APPLE_ID:-}" ]; then
  echo "==> Skipping notarization — no NOTARY_PROFILE or NOTARY_APPLE_ID/PASSWORD/TEAM_ID set."
  echo "    (DMG is built but not notarized; Gatekeeper will warn on other Macs.)"
elif [[ "$SIGNED_BY" != Developer\ ID* ]]; then
  echo "==> Skipping notarization — app is signed by '${SIGNED_BY:-none}', not a Developer ID."
  echo "    Notarization requires a 'Developer ID Application' certificate."
else
  echo "==> Notarizing (this can take a minute)…"
  if notarize_submit; then
    echo "==> Stapling ticket…"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG" && echo "==> Notarized & stapled ✅"
  else
    echo "!!  Notarization failed." >&2
    exit 1
  fi
fi

echo "==> Done: ${DMG}"
