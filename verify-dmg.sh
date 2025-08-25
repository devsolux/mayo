#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <input.dmg>" >&2
  exit 2
fi

DMG_IN="$1"
MOUNTPOINT="$(mktemp -d)"
RC=0

cleanup() {
  # detach if mounted
  if mount | grep -q "$MOUNTPOINT"; then
    hdiutil detach "$MOUNTPOINT" -quiet || hdiutil detach "$MOUNTPOINT" -force -quiet || true
  fi
  rm -rf "$MOUNTPOINT"
}
trap 'rc=$?; cleanup; exit $rc' EXIT

echo "Attaching DMG (read-only, no-browse): $DMG_IN"
hdiutil attach -nobrowse -noverify -mountpoint "$MOUNTPOINT" "$DMG_IN"

echo "Searching for .app inside mounted DMG..."
APP_PATH="$(find "$MOUNTPOINT" -maxdepth 4 -type d -name '*.app' -print -quit || true)"
if [ -z "$APP_PATH" ]; then
  echo "ERROR: no .app found inside DMG: $DMG_IN" >&2
  exit 3
fi

echo "Found app: $APP_PATH"
echo

echo "1) List top-level app contents:"
ls -la "$APP_PATH"
echo

echo "2) Check for _CodeSignature directory:"
if [ -d "$APP_PATH/Contents/_CodeSignature" ]; then
  echo "Contents/_CodeSignature:"
  ls -la "$APP_PATH/Contents/_CodeSignature"
else
  echo "No Contents/_CodeSignature directory found."
fi
echo

echo "3) codesign --verify --deep --strict --verbose=4 on the .app"
if ! codesign --verify --deep --strict --verbose=4 "$APP_PATH"; then
  echo "codesign verification FAILED" >&2
  RC=4
else
  echo "codesign verification OK"
fi
echo

echo "4) codesign -dvvv (display signature details)"
codesign -dvvv "$APP_PATH" || true
echo

# try to find the main executable inside the app
EXECUTABLE=""
if [ -f "$APP_PATH/Contents/Info.plist" ]; then
  # try to extract CFBundleExecutable if plutil available
  if command -v plutil >/dev/null 2>&1; then
    CFEXEC=$(plutil -extract CFBundleExecutable xml1 -o - "$APP_PATH/Contents/Info.plist" 2>/dev/null | \
             sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' || true)
    if [ -n "$CFEXEC" ]; then
      if [ -f "$APP_PATH/Contents/MacOS/$CFEXEC" ]; then
        EXECUTABLE="$APP_PATH/Contents/MacOS/$CFEXEC"
      fi
    fi
  fi
fi

# fallback: find first executable in Contents/MacOS
if [ -z "$EXECUTABLE" ] && [ -d "$APP_PATH/Contents/MacOS" ]; then
  EXECUTABLE="$(find "$APP_PATH/Contents/MacOS" -maxdepth 1 -type f -perm -111 -print -quit || true)"
fi

if [ -n "$EXECUTABLE" ]; then
  echo "5) Executable: $EXECUTABLE"
  echo "   codesign -d --entitlements :-"
  codesign -d --entitlements :- "$EXECUTABLE" 2>/dev/null || echo "(no entitlements or failed to read)"
  echo
else
  echo "No executable found to inspect entitlements."
  echo
fi

echo "6) spctl Gatekeeper assessment for the app (open context)"
spctl -a -t open --context context:primary-signature -vv "$APP_PATH" || RC=$((RC | 8))
echo

# Validate stapled notarization (if any)
if command -v xcrun >/dev/null 2>&1; then
  echo "7) stapler validate on the app (if stapled)"
  if xcrun stapler validate "$APP_PATH"; then
    echo "stapler validate: OK"
  else
    echo "stapler validate: FAILED or no staple present"
    RC=$((RC | 16))
  fi
  echo

  echo "8) stapler validate on the DMG (if applicable)"
  if xcrun stapler validate "$DMG_IN"; then
    echo "DMG stapler validate: OK"
  else
    echo "DMG stapler validate: FAILED or no staple present"
    RC=$((RC | 32))
  fi
  echo
else
  echo "xcrun not found; skipping stapler validate checks."
fi

echo "9) Optional: list nested signable items (frameworks, plugins, dylibs)"
find "$APP_PATH" -type d \( -name '*.framework' -o -name '*.appex' -o -name '*.plugin' \) -print -exec ls -la {} \; || true
find "$APP_PATH" -type f \( -name '*.dylib' -o -name '*.so' -o -name '*.node' \) -print -exec ls -la {} \; || true
echo

echo "Detaching DMG..."
hdiutil detach "$MOUNTPOINT" -quiet || hdiutil detach "$MOUNTPOINT" -force -quiet || true

if [ "$RC" -eq 0 ]; then
  echo "Verification completed: OK"
else
  echo "Verification completed: issues detected (exit code: $RC)" >&2
fi

exit "$RC"