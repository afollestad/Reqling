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
#
# Type-check budget readings are the exception: the compiler flags every one past TYPECHECK_BUDGET_MS, but
# `typecheck_budget_report_offenders` judges them, against TYPECHECK_TEST_BUDGET_MS for `Tests/` and with its noise
# exemptions. Counting them here would fail every test reading past the base budget, so neither could ever apply.
if [ -f "$logs_dir/test.toon" ]; then
  warning_count=$(awk '/^ *warnings: [0-9]+/ { print $2; exit }' "$logs_dir/test.toon")
  # The `warnings[n]{...}:` table lists one indented row per warning, up to the next top-level key.
  budget_reading_count=$(awk '
    /^warnings\[[0-9]+\]/ { in_table = 1; next }
    /^[^ ]/ { in_table = 0 }
    in_table && /took [0-9]+ms to type-check/ { count++ }
    END { print count + 0 }
  ' "$logs_dir/test.toon")
  if [ $(( ${warning_count:-0} - budget_reading_count )) -gt 0 ]; then
    echo "Tests emitted warnings; fix them (see warnings[] above)." >&2
    exit 1
  fi
fi
typecheck_budget_report_offenders "$logs_dir/test.log"
echo "Tests passed."
