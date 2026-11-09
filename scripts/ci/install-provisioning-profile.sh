#!/bin/bash
set -euo pipefail

: "${MACOS_PROVISIONING_PROFILE_BASE64:?}" "${RUNNER_TEMP:?}" "${GITHUB_ENV:?}"

# The Developer ID provisioning profile that lets the release claim its iCloud and push entitlements;
# `scripts/build.sh` checks and embeds whatever PROVISIONING_PROFILE names.
profile_path="$RUNNER_TEMP/Reqling.provisionprofile"
if ! printf '%s' "$MACOS_PROVISIONING_PROFILE_BASE64" | base64 --decode > "$profile_path" 2>/dev/null \
  || ! security cms -D -i "$profile_path" >/dev/null 2>&1; then
  rm -f "$profile_path"
  echo "::error title=Provisioning profile unreadable::MACOS_PROVISIONING_PROFILE_BASE64 isn't a base64 provisioning profile. Reset it with scripts/set-provisioning-profile-secret.sh, which checks it first."
  exit 1
fi
echo "PROVISIONING_PROFILE=$profile_path" >> "$GITHUB_ENV"
echo "Installed the provisioning profile for the release build"
