#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"
source "$repo_root/scripts/lib/needle.sh"
source "$repo_root/scripts/lib/typecheck-budget.sh"

# Each filter is a `swift test --filter` pattern, such as `ReqlingKitTests` or `ReqlingTests.SnapshotTests/testFoo`.
filters=()
for arg in "$@"; do
  case "$arg" in
    --no-xcsift)
      use_xcsift=false
      ;;
    -h|--help)
      echo "usage: $0 [--no-xcsift] [filter ...]"
      exit 0
      ;;
    *)
      filters+=(--filter "$arg")
      ;;
  esac
done

export SNAPSHOT_ARTIFACTS="${SNAPSHOT_ARTIFACTS:-$repo_root/.build/snapshot-failures}"
mkdir -p "$SNAPSHOT_ARTIFACTS"

generate_needle

# AppKit drives animations and scrolling from display-link ticks, which stop while the display sleeps, so a run that
# outlasts the display-sleep timer can fail UI tests spuriously. `caffeinate` holds the display and the machine awake.
keep_awake=()
if command -v caffeinate >/dev/null 2>&1; then
  keep_awake=(caffeinate -d -i)
fi

run_filtered test ${keep_awake[@]+"${keep_awake[@]}"} swift test \
  ${typecheck_budget_flags[@]+"${typecheck_budget_flags[@]}"} \
  ${filters[@]+"${filters[@]}"}

# Any warning fails the run, compiler warnings and XCTest runtime issues alike. The gate reads xcsift's `warnings`
# count, so it needs xcsift; xcodebuild-style `--Werror` would also fail on xcsift's own bookkeeping, while the test
# command's exit status stays the authority on test failures.
if [ -f "$logs_dir/test.toon" ] && grep -Eq '^ *warnings: [1-9]' "$logs_dir/test.toon"; then
  echo "Tests emitted warnings; fix them (see warnings[] above)." >&2
  exit 1
fi
typecheck_budget_report_offenders "$logs_dir/test.log"
echo "Tests passed."
