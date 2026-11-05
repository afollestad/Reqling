#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$repo_root/scripts/lib/needle.sh"
source "$repo_root/scripts/lib/typecheck-budget.sh"

usage() {
  echo "usage: $0 [--release] [--no-xcsift]" >&2
}

# Set CODESIGN_IDENTITY (e.g. "Developer ID Application") to sign either configuration for distribution. Otherwise releases
# sign ad hoc, and debug builds sign with DEBUG_CODESIGN_IDENTITY (`-` for ad hoc), else an Apple Development identity, else ad hoc.
configuration=debug
build_flags=()
for arg in "$@"; do
  case "$arg" in
    --release)
      configuration=release
      # Releases ship one universal binary for Apple silicon and Intel Macs.
      build_flags=(--arch arm64 --arch x86_64)
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
# No `--product`: one build makes both the app and the PKCS#12 helper it bundles.
run_filtered build "${swift_build[@]}"
typecheck_budget_report_offenders "$logs_dir/build.log"
bin_path=$("${swift_build[@]}" --show-bin-path)

app=$(app_path "$configuration")
dsym="$app.dSYM"
rm -rf "$app" "$dsym"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/$app_name" "$app/Contents/MacOS/"
# The app opens every PKCS#12 file in this helper first and finds it beside its own executable, by this name.
helper="$app/Contents/MacOS/ReqlingPKCS12Probe"
cp "$bin_path/ReqlingPKCS12Probe" "$helper"
cp Resources/Info.plist "$app/Contents/"

# Dependencies that declare SwiftPM resources (privacy manifests, for one) build a `<package>_<target>.bundle` beside the
# binary, and `Bundle.module` looks for it in the app's resources.
find "$bin_path" -maxdepth 1 -name '*.bundle' -type d -print0 | while IFS= read -r -d '' resource_bundle; do
  ditto "$resource_bundle" "$app/Contents/Resources/$(basename "$resource_bundle")"
done

# SwiftPM can't compile asset catalogs or Icon Composer documents, so actool builds Assets.car and AppIcon.icns.
# Pass absolute paths: actool runs in a shared daemon that resolves relative ones against its own working directory.
partial_plist=$(mktemp -t reqling-actool)
trap 'rm -f "$partial_plist"' EXIT
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
  # Ship a stripped binary; the dSYM beside the bundle symbolicates its crash reports.
  ditto "$bin_path/$app_name.dSYM" "$dsym"
  strip -rSTx "$app/Contents/MacOS/$app_name" "$helper"
fi

# Each branch signs the helper before the bundle, the same way: the bundle's signature seals its nested code, and
# updates verify it with `codesign --deep --strict`.
identity=${CODESIGN_IDENTITY:--}
if [ "$identity" != - ]; then
  # Notarization requires the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$identity" "$helper"
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
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
  # Only the app takes the requirement: the helper reads no Keychain item and holds no privacy grant.
  if ! codesign --force --timestamp=none --sign "${debug_identity:--}" "$helper" \
    || ! codesign --force --timestamp=none --sign "${debug_identity:--}" \
      --requirements "$repo_root/Config/CodeSigning/ReqlingDebugTCC.requirements" "$app"; then
    # Over SSH the login keychain is usually locked, so codesign can't reach the identity's private key.
    if [ "${debug_identity:--}" != - ]; then
      echo "error: signing with $debug_identity failed; set DEBUG_CODESIGN_IDENTITY=- to sign ad hoc" >&2
    fi
    exit 1
  fi
else
  codesign --force --sign - "$helper"
  codesign --force --sign - "$app"
fi
echo "Built $app"
