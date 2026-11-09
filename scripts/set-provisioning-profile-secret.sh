#!/bin/bash
set -euo pipefail
# common.sh changes to the repo root, so remember where a relative profile path started.
invocation_dir=$PWD
source "$(dirname "$0")/lib/common.sh"

# Stores the Developer ID provisioning profile as the MACOS_PROVISIONING_PROFILE_BASE64 secret release builds embed. The
# profile is checked as `scripts/build.sh` and `scripts/ci/verify-release-app.sh` check it first, with at least 30 days
# left, so a profile CI would reject never reaches it.
usage="usage: $0 [--dry-run] <Developer ID provisioning profile>"
dry_run=0
profile=
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=1 ;;
    -*) echo "$usage" >&2; exit 1 ;;
    *)
      case "$arg" in
        /*) ;;
        *) arg="$invocation_dir/$arg" ;;
      esac
      if [ -n "$profile" ] || [ ! -f "$arg" ]; then
        echo "$usage" >&2
        exit 1
      fi
      profile=$arg
      ;;
  esac
done
if [ -z "$profile" ]; then
  echo "$usage" >&2
  exit 1
fi

certificate=$(security find-certificate -c "Developer ID Application" -Z 2>/dev/null | awk '/SHA-1 hash:/ { print $3; exit }')
if [ -z "$certificate" ]; then
  echo "error: no Developer ID Application certificate in the keychain to check the profile against" >&2
  exit 1
fi
python3 -I "$repo_root/scripts/lib/provisioning_profile.py" check "$profile" \
  --bundle-id com.afollestad.reqling --certificate "$certificate" --distribution --min-days 30

repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
if [ "$dry_run" -eq 1 ]; then
  echo "Dry run: $(basename "$profile") is ready for CI; no secrets changed."
  exit 0
fi
base64 -i "$profile" | gh secret set MACOS_PROVISIONING_PROFILE_BASE64 -R "$repo"
echo "Set MACOS_PROVISIONING_PROFILE_BASE64 on $repo from $(basename "$profile")."
