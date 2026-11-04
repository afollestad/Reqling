#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

if ! command -v swiftlint >/dev/null 2>&1; then
  echo "error: swiftlint is required. Run ./scripts/setup.sh or install it with Homebrew." >&2
  exit 1
fi

# Run from the repo root without --config so the nested Tests/.swiftlint.yml applies. `.swiftlint.yml` sets
# `strict: true`, so every violation is an error here and in any other SwiftLint invocation.
fix=false
for arg in "$@"; do
  if [ "$arg" = --fix ] || [ "$arg" = --autocorrect ]; then
    fix=true
  fi
done

if [ "$fix" = true ]; then
  swiftlint lint --quiet "$@"
  # Autocorrection fixes what it can and exits 0 regardless; a lint pass after it fails on whatever is left.
  swiftlint lint --quiet
else
  swiftlint lint --quiet "$@"
fi
