#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: ./scripts/snapshots.sh [--no-xcsift] <verify|record> [filter ...]

Defaults to the whole `ReqlingTests.SnapshotTests` suite and its `+Topic` companions when no filter is given.

Examples:
  ./scripts/snapshots.sh verify
  ./scripts/snapshots.sh record ReqlingTests.SnapshotTests/testContentView
USAGE
}

passthrough=()
if [ "${1:-}" = --no-xcsift ]; then
  passthrough+=(--no-xcsift)
  shift
fi

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 1
fi
mode=$1
shift
case "$mode" in
  verify|record)
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

if [ "$#" -eq 0 ]; then
  set -- "ReqlingTests.SnapshotTests"
fi

export SNAPSHOT_ARTIFACTS="$repo_root/.build/snapshot-failures"
rm -rf "$SNAPSHOT_ARTIFACTS"

if [ "$mode" = record ]; then
  # `swift test` hands the environment straight to the test process, so this reaches SnapshotTesting. Recording fails
  # every test it records, by design, so the status says nothing about the baselines; the verify pass below is the judge.
  set +e
  RECORD_SNAPSHOTS=1 "$repo_root/scripts/test.sh" ${passthrough[@]+"${passthrough[@]}"} "$@"
  record_status=$?
  set -e
  if [ "$record_status" -ne 0 ]; then
    echo "Snapshot record run exited $record_status; verifying the recorded references..."
  fi
fi

"$repo_root/scripts/test.sh" ${passthrough[@]+"${passthrough[@]}"} "$@"
if [ "$mode" = record ]; then
  echo "Snapshots recorded and verified."
else
  echo "Snapshot verification passed."
fi
