#!/bin/bash
set -euo pipefail

: "${EXPORT_PATH:?}" "${RELEASE_PATH:?}" "${APP_NAME:?}" "${GITHUB_OUTPUT:?}"

# Release builds ship stripped executables, the app's and each helper's, so a crash report symbolicates only
# against these dSYMs, and nothing else keeps them once the runner is discarded. Package them for every mode
# that hands out a binary.
#
# Every executable in `Contents/MacOS` must have one, so a new helper cannot ship without symbols. The main
# executable's is `<app>.app.dSYM`, as Xcode names it; a helper's is `<helper>.dSYM`.
dsyms_dir="$EXPORT_PATH/dSYMs"
macos_dir="$EXPORT_PATH/${APP_NAME}.app/Contents/MacOS"

shopt -s nullglob
binaries=("$macos_dir"/*)
if [ ${#binaries[@]} -eq 0 ]; then
  echo "error: no executables in $macos_dir" >&2
  exit 1
fi

for binary in "${binaries[@]}"; do
  name=$(basename "$binary")
  if [ "$name" = "$APP_NAME" ]; then
    dsym="$dsyms_dir/${APP_NAME}.app.dSYM"
  else
    dsym="$dsyms_dir/${name}.dSYM"
  fi
  if [ ! -d "$dsym" ]; then
    echo "error: build has no dSYM for ${name}: $dsym" >&2
    exit 1
  fi

  # Crash reports match a dSYM by UUID alone, so a dSYM from another build reads as "no symbols" months
  # later. `|| true` turns an unreadable file into an empty list, rejected below rather than passing
  # vacuously.
  dsym_uuids=$(dwarfdump --uuid "$dsym" 2>/dev/null | awk '{print $2}' | tr '\n' ' ') || true
  binary_uuids=$(dwarfdump --uuid "$binary" 2>/dev/null | awk '{print $2}' | tr '\n' ' ') || true
  if [ -z "${binary_uuids// /}" ] || [ -z "${dsym_uuids// /}" ]; then
    echo "error: no UUIDs read for ${name} (binary: '${binary_uuids}', dSYM: '${dsym_uuids}')" >&2
    echo "hint: expected a Mach-O at $binary and DWARF inside $dsym" >&2
    exit 1
  fi

  for uuid in $binary_uuids; do
    case " $dsym_uuids " in
      *" $uuid "*) ;;
      *)
        echo "error: shipped ${name} slice $uuid is missing from $dsym" >&2
        echo "binary: $binary_uuids" >&2
        echo "dSYM:   $dsym_uuids" >&2
        exit 1
        ;;
    esac
  done
  echo "dSYM covers every shipped ${name} slice: $binary_uuids"
done

# The folder's contents, not the folder, so each extracted `.dSYM` sits at the top, where `atos -o` and
# crash-report tools take it directly.
mkdir -p "$RELEASE_PATH"
dsym_path="$RELEASE_PATH/${APP_NAME}.dSYMs.zip"
ditto -c -k "$dsyms_dir" "$dsym_path"
echo "dsym_path=$dsym_path" >> "$GITHUB_OUTPUT"
