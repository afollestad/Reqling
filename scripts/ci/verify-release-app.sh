#!/bin/bash
set -euo pipefail

: "${EXPORT_PATH:?}" "${APP_NAME:?}" "${VERSION:?}" "${BUILD:?}" "${APPLE_TEAM_ID:?}"

app_path="$EXPORT_PATH/${APP_NAME}.app"
info_plist="$app_path/Contents/Info.plist"

actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")
actual_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")
if [ "$actual_version" != "$VERSION" ] || [ "$actual_build" != "$BUILD" ]; then
  echo "error: app has version ${actual_version} (${actual_build}), expected ${VERSION} (${BUILD})" >&2
  exit 1
fi

# `scripts/build.sh` rewrites the identifier for debug builds; the updater rejects any other identity.
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")
if [ "$bundle_identifier" != com.afollestad.reqling ]; then
  echo "error: app has bundle identifier ${bundle_identifier}, expected com.afollestad.reqling" >&2
  exit 1
fi

codesign --verify --deep --strict --verbose=2 "$app_path"

# The app and every helper beside it run as their own processes, so each needs its own Developer ID
# signature and hardened runtime for notarization, and must be executable. Checking every file rather than
# naming the helpers keeps a new one from shipping unchecked.
shopt -s nullglob
executables=("$app_path/Contents/MacOS"/*)
if [ ${#executables[@]} -eq 0 ]; then
  echo "error: no executables in $app_path/Contents/MacOS" >&2
  exit 1
fi
for executable in "${executables[@]}"; do
  name=$(basename "$executable")
  if [ ! -x "$executable" ]; then
    echo "error: ${name} is not executable" >&2
    exit 1
  fi
  signature=$(codesign --display --verbose=2 "$executable" 2>&1)
  if ! grep -q '^Authority=Developer ID Application:' <<< "$signature"; then
    echo "error: ${name} is not signed with a Developer ID Application certificate" >&2
    exit 1
  fi
  if ! grep -qx "TeamIdentifier=${APPLE_TEAM_ID}" <<< "$signature"; then
    echo "error: ${name} is not signed by team ${APPLE_TEAM_ID}" >&2
    exit 1
  fi
  # Notarization rejects binaries without the hardened runtime.
  if ! grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<< "$signature"; then
    echo "error: ${name} is not signed with the hardened runtime" >&2
    exit 1
  fi
  # Releases ship for Apple silicon only (`scripts/build.sh`).
  architectures=$(lipo -archs "$executable")
  if [ "$architectures" != arm64 ]; then
    echo "error: ${name} has architectures '${architectures}', expected arm64 alone" >&2
    exit 1
  fi
done

echo "Verified ${APP_NAME} ${VERSION} (${BUILD}): ${#executables[@]} executables, Developer ID signed, hardened runtime, arm64"
