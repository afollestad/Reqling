#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

build_first=false
for arg in "$@"; do
  case "$arg" in
    -b|--build)
      build_first=true
      ;;
    *)
      echo "usage: $0 [-b|--build]" >&2
      exit 1
      ;;
  esac
done

app=$(app_path debug)
if [ "$build_first" = true ]; then
  "$repo_root/scripts/build.sh"
elif [ ! -d "$app" ]; then
  echo "$app_name.app not found, building first..."
  "$repo_root/scripts/build.sh"
fi

# Match the dev bundle's executable path rather than the process name: an installed release build runs an executable
# with the same name and must be left alone.
executable_pattern="^$(printf '%s' "$app/Contents/MacOS/$app_name" | sed 's/[][\.*^$+?(){}|]/\\&/g')"
if pgrep -f "$executable_pattern" >/dev/null; then
  pkill -f "$executable_pattern"
  attempt=0
  while pgrep -f "$executable_pattern" >/dev/null && [ "$attempt" -lt 50 ]; do
    sleep 0.1
    attempt=$((attempt + 1))
  done
  if pgrep -f "$executable_pattern" >/dev/null; then
    pkill -9 -f "$executable_pattern"
  fi
fi

open "$app"
