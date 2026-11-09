#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$repo_root/scripts/lib/needle.sh"
source "$repo_root/scripts/lib/typecheck-budget.sh"

usage() {
  echo "usage: $0 [--release] [--no-xcsift]" >&2
}

# Set CODESIGN_IDENTITY (e.g. "Developer ID Application") to sign either configuration for distribution; a release signed
# that way also needs PROVISIONING_PROFILE. Otherwise releases sign ad hoc, and debug builds sign with
# DEBUG_CODESIGN_IDENTITY (`-` for ad hoc), else an Apple Development identity, else ad hoc.
configuration=debug
build_flags=()
for arg in "$@"; do
  case "$arg" in
    --release)
      configuration=release
      # Releases ship for Apple silicon only, whatever Mac builds them; Reqling doesn't support Intel Macs.
      build_flags=(--arch arm64)
      ;;
    --no-xcsift)
      use_xcsift=false
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

generate_needle

# The `+` guards keep macOS's bash 3.2 from treating an empty array as unbound under `set -u`.
swift_build=(swift build -c "$configuration" ${build_flags[@]+"${build_flags[@]}"} ${typecheck_budget_flags[@]+"${typecheck_budget_flags[@]}"})
# No `--product`: one build makes the app and the helpers it bundles.
run_filtered build "${swift_build[@]}"
typecheck_budget_report_offenders "$logs_dir/build.log"
bin_path=$("${swift_build[@]}" --show-bin-path)

app=$(app_path "$configuration")
dsyms=$(dsyms_path "$configuration")
rm -rf "$app" "$dsyms"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/$app_name" "$app/Contents/MacOS/"
# The app finds each helper beside its own executable, by these names: it opens every PKCS#12 file in the first, and
# runs scripts in the second, which reads its JavaScript from `Contents/Resources/ScriptRuntime`.
helpers=()
for helper_name in ReqlingPKCS12Probe ReqlingScriptRunner; do
  helpers+=("$app/Contents/MacOS/$helper_name")
  cp "$bin_path/$helper_name" "$app/Contents/MacOS/$helper_name"
done
ditto "$repo_root/Sources/ReqlingScriptRunner/Runtime" "$app/Contents/Resources/ScriptRuntime"
cp Resources/Info.plist "$app/Contents/"

# Dependencies that declare SwiftPM resources (privacy manifests, for one) build a `<package>_<target>.bundle` beside the
# binary, and `Bundle.module` looks for it in the app's resources. This package's test targets build theirs into the same
# folder whenever tests build, and those hold only fixtures, so they stay out, picked by target type rather than by name.
test_bundles=$(swift package describe --type json | python3 -c '
import json, sys
package = json.load(sys.stdin)
for target in package["targets"]:
    if target["type"] == "test":
        print(package["name"] + "_" + target["name"] + ".bundle")
')
find "$bin_path" -maxdepth 1 -name '*.bundle' -type d -print0 | while IFS= read -r -d '' resource_bundle; do
  bundle_name=$(basename "$resource_bundle")
  if printf '%s\n' "$test_bundles" | grep -qxF "$bundle_name"; then
    continue
  fi
  ditto "$resource_bundle" "$app/Contents/Resources/$bundle_name"
done

# SwiftPM can't compile asset catalogs or Icon Composer documents, so actool builds Assets.car and AppIcon.icns.
# Pass absolute paths: actool runs in a shared daemon that resolves relative ones against its own working directory.
partial_plist=$(mktemp -t reqling-actool)
trap 'rm -f "$partial_plist" "${entitlements_file:-}"' EXIT
if ! actool_output=$(xcrun actool "$repo_root/Resources/Assets.xcassets" "$repo_root/Resources/AppIcon.icon" \
  --compile "$app/Contents/Resources" \
  --platform macosx \
  --minimum-deployment-target 26.0 \
  --app-icon AppIcon \
  --accent-color AccentColor \
  --output-partial-info-plist "$partial_plist" \
  --output-format human-readable-text \
  --errors --warnings 2>&1); then
  echo "$actool_output" >&2
  exit 1
fi
# Show diagnostics, but not the list of compiled files.
echo "$actool_output" | awk '/^\/\* com.apple.actool.compilation-results \*\//{skip=1; next} /^\/\* /{skip=0} !skip && NF'
# actool exits 0 when `--app-icon` matches nothing, leaving the app without an icon.
if [ ! -f "$app/Contents/Resources/AppIcon.icns" ]; then
  echo "error: actool did not produce AppIcon.icns; check Resources/AppIcon.icon" >&2
  exit 1
fi
/usr/libexec/PlistBuddy -c "Merge $partial_plist" "$app/Contents/Info.plist" >/dev/null

if [ "$configuration" = debug ]; then
  # A separate identity keeps the dev build's preferences, Application Support folder, Keychain items, and privacy grants
  # apart from the release build's. Config/CodeSigning/ReqlingDebugTCC.requirements names this identifier too.
  /usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier com.afollestad.reqling.debug" \
    -c "Set :CFBundleDisplayName Reqling Dev" \
    -c "Set :CFBundleName Reqling Dev" \
    "$app/Contents/Info.plist"
else
  # Ship stripped binaries; the dSYMs beside the bundle symbolicate their crash reports.
  mkdir -p "$dsyms"
  ditto "$bin_path/$app_name.dSYM" "$dsyms/$app_name.app.dSYM"
  for helper in "${helpers[@]}"; do
    helper_name=$(basename "$helper")
    ditto "$bin_path/$helper_name.dSYM" "$dsyms/$helper_name.dSYM"
  done
  strip -rSTx "$app/Contents/MacOS/$app_name" "${helpers[@]}"
fi

# iCloud sync: macOS honors the iCloud and push entitlements only when the embedded provisioning profile allows them,
# and won't launch an app that claims one its profile doesn't. So a profile is checked first
# (`scripts/lib/provisioning_profile.py`), then embedded with its entitlements, or neither goes on. Only the app gets
# them; the helpers use no iCloud.
profile_tool=(python3 -I "$repo_root/scripts/lib/provisioning_profile.py")
entitlement_flags=()

# The SHA-1 of the certificate `codesign --sign "$1"` signs with.
certificate_hash() {
  if [[ $1 =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "$1"
  else
    security find-certificate -c "$1" -Z 2>/dev/null | awk '/SHA-1 hash:/ { print $3; exit }'
  fi
}

# Embeds profile $1 and signs the app with template $2's entitlements plus the identifiers $1 grants.
use_profile() {
  entitlements_file=$(mktemp -t reqling-entitlements)
  "${profile_tool[@]}" entitlements "$1" "$2" "$entitlements_file"
  cp "$1" "$app/Contents/embedded.provisionprofile"
  entitlement_flags=(--entitlements "$entitlements_file")
}

# Each branch signs the helpers before the bundle, the same way: the bundle's signature seals its nested code, and
# updates verify it with `codesign --deep --strict`.
identity=${CODESIGN_IDENTITY:--}
if [ "$identity" != - ]; then
  if [ "$configuration" = release ]; then
    # A release without sync would ship silently, so a missing or unusable profile stops it.
    if [ -z "${PROVISIONING_PROFILE:-}" ]; then
      echo "error: set PROVISIONING_PROFILE to the Developer ID provisioning profile (RELEASING.md)" >&2
      exit 1
    fi
    "${profile_tool[@]}" check "$PROVISIONING_PROFILE" --bundle-id com.afollestad.reqling \
      --certificate "$(certificate_hash "$identity")" --distribution
    use_profile "$PROVISIONING_PROFILE" "$repo_root/Config/Entitlements/Reqling.entitlements"
  fi
  # Notarization requires the hardened runtime and a secure timestamp.
  for helper in "${helpers[@]}"; do
    codesign --force --options runtime --timestamp --sign "$identity" "$helper"
  done
  codesign --force --options runtime --timestamp --sign "$identity" ${entitlement_flags[@]+"${entitlement_flags[@]}"} "$app"
elif [ "$configuration" = debug ]; then
  # macOS ties Keychain items to the code that may read them twice: the ACL checks the designated requirement, and the
  # partition list checks the signer. Ad hoc code's partition is its cdhash, which every rebuild changes, so each build
  # would prompt for every item; an Apple Development signature's partition is its team ID, which rebuilds keep. The
  # identifier-only requirement keeps the ACL and the Local Network grant matching any signer, ad hoc fallback included.
  # The hash, not the name, picks the identity: codesign refuses a name that several certificates share.
  debug_identity=${DEBUG_CODESIGN_IDENTITY:-}
  if [ -z "$debug_identity" ]; then
    debug_identity=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development: /{print $2}' | head -n 1 || true)
  fi
  # Reqling Dev syncs against CloudKit's Development environment when a development profile for it lists this Mac:
  # DEBUG_PROVISIONING_PROFILE, which must be usable, or the longest-lasting usable one Xcode's profile folder holds.
  if [ "${debug_identity:--}" != - ]; then
    certificate=$(certificate_hash "$debug_identity")
    device=$(system_profiler SPHardwareDataType 2>/dev/null | awk -F': ' '/Provisioning UDID/ { print $2; exit }')
    debug_profile=${DEBUG_PROVISIONING_PROFILE:-}
    if [ -n "$debug_profile" ]; then
      "${profile_tool[@]}" check "$debug_profile" --bundle-id com.afollestad.reqling.debug --certificate "$certificate" --device "$device"
    else
      debug_profile=$("${profile_tool[@]}" find "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
        --bundle-id com.afollestad.reqling.debug --certificate "$certificate" --device "$device" || true)
    fi
    if [ -n "$debug_profile" ]; then
      use_profile "$debug_profile" "$repo_root/Config/Entitlements/ReqlingDebug.entitlements"
    else
      echo "note: no usable Reqling Dev provisioning profile, so this build can't sync with iCloud (README, Debug builds)" >&2
    fi
  fi
  # Only the app takes the requirement: the helpers read no Keychain item and hold no privacy grant.
  signed_helpers=true
  for helper in "${helpers[@]}"; do
    codesign --force --timestamp=none --sign "${debug_identity:--}" "$helper" || signed_helpers=false
  done
  if [ "$signed_helpers" != true ] \
    || ! codesign --force --timestamp=none --sign "${debug_identity:--}" ${entitlement_flags[@]+"${entitlement_flags[@]}"} \
      --requirements "$repo_root/Config/CodeSigning/ReqlingDebugTCC.requirements" "$app"; then
    # Over SSH the login keychain is usually locked, so codesign can't reach the identity's private key.
    if [ "${debug_identity:--}" != - ]; then
      echo "error: signing with $debug_identity failed; set DEBUG_CODESIGN_IDENTITY=- to sign ad hoc" >&2
    fi
    exit 1
  fi
else
  for helper in "${helpers[@]}"; do
    codesign --force --sign - "$helper"
  done
  codesign --force --sign - "$app"
fi
echo "Built $app"
