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
rm -rf build/dmg-stage   # tidy leftovers from older runs

# Don't package (or rebuild the signature of) a running instance — a live app bundle
# locks files and makes `hdiutil create` fail with "Resource busy".
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Quitting running ${APP_NAME}…"
  osascript -e "tell application \"${APP_NAME}\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do pgrep -x "$APP_NAME" >/dev/null 2>&1 || break; sleep 0.2; done
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

echo "==> Building app…"
./build-app.sh

# Stage and build the image in a temp dir OUTSIDE the repo. Creating it inside build/
# races Spotlight (mdworker) indexing that folder and fails with "Resource busy".
WORK="$(mktemp -d "${TMPDIR:-/tmp}/thunderbox-dmg.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
TMP_DMG="$WORK/${APP_NAME}.dmg"

echo "==> Staging disk image…"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"   # drag-to-install target

echo "==> Creating ${DMG}…"
# Build the filesystem directly with makehybrid (it attaches no temporary device, so it
# avoids the flaky `hdiutil create -srcfolder` "Resource busy" failure), then compress.
hdiutil makehybrid -hfs -hfs-volume-name "$APP_NAME" -ov -o "$WORK/raw.dmg" "$STAGE" >/dev/null
hdiutil convert "$WORK/raw.dmg" -format UDZO -ov -o "$TMP_DMG" >/dev/null
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG"
mv -f "$TMP_DMG" "$DMG"
rm -rf "$WORK"; trap - EXIT

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
# Capture codesign output first, then parse the variable — piping codesign straight into
# `awk '…exit'` makes awk close the pipe early, SIGPIPE-ing codesign, which under
# `set -o pipefail` would abort the script before we reach notarization.
CODESIGN_OUT=$(codesign -dvv "$APP" 2>&1 || true)
SIGNED_BY=$(awk -F'Authority=' '/Authority=/{print $2; exit}' <<< "$CODESIGN_OUT")
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
