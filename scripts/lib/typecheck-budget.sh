# Shared type-check budget flags; source it after scripts/lib/common.sh.
#
# Swift solves an expression as a whole, and when the solver runs out of time it hard-errors instead of warning. That
# limit is wall-clock, so an over-budget SwiftUI body compiles fine on a fast machine and fails only on slower hardware.
# Setting TYPECHECK_BUDGET_MS asks the frontend to warn past that many milliseconds, and `build.sh` and `test.sh` fail
# on any such warning in this repo's own sources.
#
# Every entry point applies the same flags. SwiftPM applies `-Xswiftc` to the whole graph, so an entry point that
# passed different flags would see different build settings and recompile everything, dependencies included.
#
# Populates `typecheck_budget_flags`. Expand it as "${typecheck_budget_flags[@]+"${typecheck_budget_flags[@]}"}" so an
# empty array stays safe under `set -u` on macOS's bash 3.2.

typecheck_budget_flags=()
if [ -n "${TYPECHECK_BUDGET_MS:-}" ]; then
  typecheck_budget_flags+=(
    -Xswiftc -Xfrontend -Xswiftc "-warn-long-function-bodies=${TYPECHECK_BUDGET_MS}"
    -Xswiftc -Xfrontend -Xswiftc "-warn-long-expression-type-checking=${TYPECHECK_BUDGET_MS}"
  )
fi

# Repo-relative path prefixes exempt from the failure scan, one per line; their readings still print as warnings.
#
# The solver's wall-clock timer bills first-touch framework deserialization to whichever expression in a frontend batch
# needs it first, so a trivial statement can report several seconds on a slow machine while solving in under 100ms
# locally. Add a prefix only with a measurement showing that signature: multi-second on the slow machine, trivial
# locally, and invariant to how the statement is written. Prove the last part by putting a throwaway function doing
# strictly *less* ahead of the reported one and confirming the whole bill moves onto it. Exempt a path rather than
# raising the budget: the noise drifts upward across toolchains, so a raise only buys time.
#
# Matching is literal, through awk's `index`, and the prefixes are joined with commas, so a prefix may not contain one.
typecheck_budget_exempt_prefixes=""

# Fails when a raw build log contains an over-budget diagnostic for this repo's own sources.
#
# `Tests/` sources fail at TYPECHECK_TEST_BUDGET_MS (defaulting to the base budget) and everything else at
# TYPECHECK_BUDGET_MS. The compiler flag stays at the base value everywhere, so every entry point shares one set of build
# products; sub-threshold test readings still surface as plain warnings. Dependency sources under `.build/` are not ours
# to change, so they are skipped. A run only reports files it actually recompiled, so an incremental pass can miss an
# untouched offender; change the budget value or clean for the full picture.
typecheck_budget_report_offenders() {
  local log_path=$1
  if [ -z "${TYPECHECK_BUDGET_MS:-}" ] || [ ! -f "$log_path" ]; then
    return 0
  fi
  local source_limit=$TYPECHECK_BUDGET_MS
  local test_limit=${TYPECHECK_TEST_BUDGET_MS:-$TYPECHECK_BUDGET_MS}
  local offenders
  offenders=$(
    grep -E "took [0-9]+ms to type-check" "$log_path" \
      | awk -v root="$repo_root/" -v build="$repo_root/.build/" \
        -v source_limit="$source_limit" -v test_limit="$test_limit" \
        -v exempt="$(printf '%s' "$typecheck_budget_exempt_prefixes" | tr '\n' ',')" \
        'BEGIN { exempt_count = split(exempt, exempt_prefixes, ",") }
         index($0, root) == 1 && index($0, build) != 1 {
           line = substr($0, length(root) + 1)
           for (i = 1; i <= exempt_count; i++) {
             if (exempt_prefixes[i] != "" && index(line, exempt_prefixes[i]) == 1) { next }
           }
           limit = index(line, "Tests/") == 1 ? test_limit : source_limit
           if (match(line, /took [0-9]+ms to type-check/)) {
             ms = substr(line, RSTART + 5)
             sub(/ms.*/, "", ms)
             if (ms + 0 >= limit + 0) { print line }
           }
         }' \
      | sort -u || true
  )

  if [ -z "$offenders" ]; then
    return 0
  fi

  echo "" >&2
  echo "Type-check budget exceeded (sources ${source_limit}ms, tests ${test_limit}ms):" >&2
  echo "$offenders" >&2
  echo "" >&2
  echo "Split each into parts that type-check on their own; see the type-check budget bullets in AGENTS.md." >&2
  return 1
}
