#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$repo_root/scripts/lib/needle.sh"
source "$repo_root/scripts/lib/typecheck-budget.sh"

usage() {
  echo "usage: $0 [--release] [--no-xcsift]" >&2
}

# Signs ad hoc by default; set CODESIGN_IDENTITY (e.g. "Developer ID Application") to sign for distribution.
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
run_filtered build "${swift_build[@]}" --product "$app_name"
typecheck_budget_report_offenders "$logs_dir/build.log"
bin_path=$("${swift_build[@]}" --show-bin-path)

app=$(app_path "$configuration")
dsym="$app.dSYM"
rm -rf "$app" "$dsym"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/$app_name" "$app/Contents/MacOS/"
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
  strip -rSTx "$app/Contents/MacOS/$app_name"
fi

identity=${CODESIGN_IDENTITY:--}
if [ "$identity" != - ]; then
  # Notarization requires the hardened runtime and a secure timestamp.
  codesign --force --options runtime --timestamp --sign "$identity" "$app"
elif [ "$configuration" = debug ]; then
  # An ad hoc signature's default designated requirement pins the binary's hash, which every rebuild changes, so the
  # Local Network grant and Keychain access would be lost each time. An identifier-based requirement survives rebuilds.
  codesign --force --sign - --requirements "$repo_root/Config/CodeSigning/ReqlingDebugTCC.requirements" "$app"
else
  codesign --force --sign - "$app"
fi
echo "Built $app"
