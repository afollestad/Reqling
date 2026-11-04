#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$repo_root/scripts/lib/needle.sh"

if ! command -v brew >/dev/null 2>&1; then
  echo "error: Homebrew is required. Install it from https://brew.sh/ and rerun this script." >&2
  exit 1
fi

# protobuf supplies `protoc` for the proto-import tests and for regenerating committed protobuf code.
for formula in xcsift swiftlint needle protobuf; do
  if brew list --formula "$formula" >/dev/null 2>&1; then
    echo "$formula already installed"
  else
    brew install "$formula"
  fi
done
require_needle

echo "Resolving Swift packages..."
swift package resolve

if [ "${CI:-false}" = true ]; then
  echo "Skipping Git hook installation in CI."
elif ! git -C "$repo_root" rev-parse --git-dir >/dev/null 2>&1; then
  echo "warning: not a Git repository; skipping hook installation." >&2
elif ! "$repo_root/scripts/install-git-hooks.sh"; then
  echo "warning: Git hook installation failed; continuing setup." >&2
fi

green=$(printf '\033[32m')
reset=$(printf '\033[0m')
echo "Setup complete. Next steps:"
echo "  Build with ${green}./scripts/build.sh${reset}, run with ${green}./scripts/run.sh -b${reset}, test with ${green}./scripts/test.sh${reset},"
echo "  lint with ${green}./scripts/lint.sh${reset}, and verify snapshots with ${green}./scripts/snapshots.sh verify${reset}."
