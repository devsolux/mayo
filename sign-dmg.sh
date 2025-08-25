#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <input.dmg> <Developer ID Application signing identity> [output.dmg]" >&2
  exit 2
fi

DMG_IN="$1"
SIGN_ID="$2"
DMG_OUT="${3:-${DMG_IN%.dmg}-signed.dmg}"

TMPDIR="$(mktemp -d)"
MOUNTPOINT="$(mktemp -d)"

cleanup() {
  # try to detach if mounted
  if mount | grep -q "$MOUNTPOINT"; then
    hdiutil detach "$MOUNTPOINT" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMPDIR" "$MOUNTPOINT"
}
trap 'rc=$?; cleanup; exit $rc' EXIT

# attach DMG read-only
hdiutil attach -nobrowse -noverify -mountpoint "$MOUNTPOINT" "$DMG_IN"

# locate .app inside mounted dmg
APP_PATH="$(find "$MOUNTPOINT" -maxdepth 3 -type d -name '*.app' -print -quit || true)"
if [ -z "$APP_PATH" ]; then
  echo "error: no .app found inside DMG" >&2
  exit 3
fi

APP_NAME="$(basename "$APP_PATH")"
WORK_APP="$TMPDIR/$APP_NAME"

# copy app out preserving all resource forks and metadata
ditto "$APP_PATH" "$WORK_APP"

# sign nested frameworks, .appex, plugins, kexts first (if any)
find "$WORK_APP" -maxdepth 6 -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.plugin' -o -name '*.kext' \) -print0 |
  while IFS= read -r -d '' item; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$item"
  done

# sign executables inside Contents (helpers, helpers apps, binaries)
if [ -d "$WORK_APP/Contents" ]; then
  find "$WORK_APP/Contents" -type f -perm -111 -print0 |
    while IFS= read -r -d '' exe; do
      # attempt to codesign; ignore failures for non-signable files
      codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$exe" 2>/dev/null || true
    done
fi

# sign dylibs and other non-directory code files
find "$WORK_APP" -type f \( -name '*.dylib' -o -name '*.so' \) -print0 |
  while IFS= read -r -d '' lib; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$lib" 2>/dev/null || true
  done

# sign the top-level app (after signing nested items)
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$WORK_APP"

# verify the app signature
codesign --verify --deep --strict --verbose=4 "$WORK_APP"

# create a new compressed DMG containing the signed app
hdiutil create -volname "${APP_NAME%.*}" -srcfolder "$WORK_APP" -ov -format UDZO "$DMG_OUT"

# codesign the resulting DMG (so the disk image itself is signed)
codesign --force --timestamp --sign "$SIGN_ID" "$DMG_OUT"

# optional: quick Gatekeeper check on the DMG
spctl -a -t open --context context:primary-signature -vv "$DMG_OUT" || true

echo "Signed DMG created: $DMG_OUT"