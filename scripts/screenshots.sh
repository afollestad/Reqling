#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: ./scripts/screenshots.sh [-b|--build] [-o|--output <dir>] [scene ...]

Captures the main window in each screenshot scene (`ScreenshotMode.Scene`: request, body, grpc, graphql, events,
websocket), or only those named, in light and dark, as <dir>/<scene>-<light|dark>.png, `.build/screenshots` by default.
Each is the window alone at 2x, with transparent rounded corners and no shadow. `-b` builds the debug app first.

Each launch runs a copy of the debug app re-identified as `com.afollestad.reqling.shots`, with
`-DebugScreenshotScene` seeding a demo project into throwaway storage, so neither the dev build's projects nor its
preferences are touched. Nothing is clicked or typed: the copy opens without taking focus, so it shows the inactive
window appearance, and its window ignores the pointer, so no hover effect shows and clicks pass through it. Needs a
Retina display and Screen Recording access for the terminal.
USAGE
}

build_first=false
output_dir="$repo_root/.build/screenshots"
scenes=()
while [ $# -gt 0 ]; do
  case "$1" in
    -b|--build)
      build_first=true
      shift
      ;;
    -o|--output)
      if [ $# -lt 2 ]; then
        echo "error: $1 needs a value" >&2
        exit 1
      fi
      output_dir=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    request|body|grpc|graphql|events|websocket)
      scenes+=("$1")
      shift
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done
if [ ${#scenes[@]} -eq 0 ]; then
  scenes=(request body grpc graphql events websocket)
fi

app=$(app_path debug)
if [ "$build_first" = true ]; then
  "$repo_root/scripts/build.sh"
elif [ ! -d "$app" ]; then
  echo "$app_name.app not found, building first..."
  "$repo_root/scripts/build.sh"
fi

work_dir="$repo_root/.build/screenshot-work"
shots_app="$work_dir/$app_name.app"
shots_bundle_id="com.afollestad.reqling.shots"
# `ScreenshotMode`'s storage: `AppStorageProfile.screenshots` names this defaults suite and this folder under the
# app's temporary directory, which is the per-user one even when the shell's TMPDIR points elsewhere.
screenshot_suite="com.afollestad.reqling.screenshots"
screenshot_storage="$(getconf DARWIN_USER_TEMP_DIR)ReqlingScreenshots"
executable_pattern="^$(printf '%s' "$shots_app/Contents/MacOS/$app_name" | sed 's/[][\.*^$+?(){}|]/\\&/g')"

stop_app() {
  pkill -f "$executable_pattern" 2>/dev/null || true
  local attempt=0
  while pgrep -f "$executable_pattern" >/dev/null && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  pkill -9 -f "$executable_pattern" 2>/dev/null || true
}

cleanup() {
  stop_app
  defaults delete "$shots_bundle_id" >/dev/null 2>&1 || true
  defaults delete "$screenshot_suite" >/dev/null 2>&1 || true
  rm -rf "$screenshot_storage" "$work_dir/frames"
}
trap cleanup EXIT

rm -rf "$work_dir"
mkdir -p "$work_dir/frames" "$output_dir"
xcrun swiftc -O "$repo_root/scripts/lib/screenshot-window.swift" -o "$work_dir/screenshot-window"
helper="$work_dir/screenshot-window"

# A copy under its own bundle identifier keeps its window frame and saved state out of the dev build's preferences.
# Re-identifying breaks the signature, so it is signed again ad hoc; screenshot mode never reaches the Keychain.
ditto "$app" "$shots_app"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $shots_bundle_id" "$shots_app/Contents/Info.plist"
if ! codesign --force --sign - "$shots_app" 2>"$work_dir/codesign.log"; then
  cat "$work_dir/codesign.log" >&2
  exit 1
fi

# Prints the pid of the running copy once its main window is on screen, giving up after 30 seconds.
wait_for_window() {
  local pid="" attempt
  for attempt in $(seq 1 300); do
    pid=${pid:-$(pgrep -f "$executable_pattern" | head -n 1 || true)}
    if [ -n "$pid" ] && "$helper" "$pid" >/dev/null; then
      echo "$pid"
      return 0
    fi
    sleep 0.1
  done
  echo "error: the screenshot window never appeared" >&2
  return 1
}

# Captures process `$1`'s main window to `$2` once it stops changing: two frames a second apart that match, at the same
# width. The window still grows to its default size after it first appears, so it is looked up again for every frame.
# Prints the window's final width in points. Gives up after 30 seconds.
capture_settled() {
  local pid=$1 destination=$2
  local previous="$work_dir/frames/previous.png" current="$work_dir/frames/current.png"
  local attempt window previous_window="" window_id width
  for attempt in $(seq 1 30); do
    sleep 1
    # Checked explicitly: this runs inside `$(...)`, where bash 3.2 ignores `set -e`.
    if ! window=$("$helper" "$pid"); then
      echo "error: the screenshot window closed or left the screen" >&2
      return 1
    fi
    read -r window_id width <<<"$window"
    if ! screencapture -x -o -l"$window_id" "$current"; then
      echo "error: screencapture failed; give the terminal Screen Recording access" >&2
      return 1
    fi
    if [ "$window" = "$previous_window" ] && cmp -s "$previous" "$current"; then
      mv "$current" "$destination"
      echo "$width"
      return 0
    fi
    mv "$current" "$previous"
    previous_window=$window
  done
  echo "error: the window never settled" >&2
  return 1
}

for scene in "${scenes[@]}"; do
  for theme in light dark; do
    stop_app
    defaults delete "$shots_bundle_id" >/dev/null 2>&1 || true
    # -g keeps it from taking focus; -n opens a new copy even while another runs.
    open -n -g -a "$shots_app" --args \
      -DebugScreenshotScene "$scene" -DebugScreenshotTheme "$theme" -ApplePersistenceIgnoreState YES
    pid=$(wait_for_window)
    destination="$output_dir/$scene-$theme.png"
    width=$(capture_settled "$pid" "$destination")
    pixel_width=$(sips -g pixelWidth "$destination" | awk '/pixelWidth/ {print $2}')
    if [ "$pixel_width" -ne $((width * 2)) ]; then
      echo "error: $destination is ${pixel_width}px wide for a ${width}pt window; capture on a Retina display" >&2
      exit 1
    fi
    echo "Saved $destination"
  done
done
