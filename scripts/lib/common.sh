# Shared setup for scripts/*.sh; source it, don't execute it.

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$repo_root"

app_name=Reqling
logs_dir="$repo_root/.build/logs"

# The assembled bundle for a build configuration (`debug` or `release`). Release builds put its dSYM at "<bundle>.dSYM".
app_path() {
  echo "$repo_root/.build/app/$1/$app_name.app"
}

# Entry points turn this off for `--no-xcsift`; NO_XCSIFT=1 does the same from the environment.
use_xcsift=true
if [ "${NO_XCSIFT:-0}" = 1 ]; then
  use_xcsift=false
fi

# Runs a command, always teeing its raw output to .build/logs/<log-name>.log, and condensing what the terminal shows
# through `xcsift -f toon -w` (kept in .build/logs/<log-name>.toon) when xcsift is installed and enabled.
#
# When the command fails and xcsift printed nothing (output it does not recognize, such as a package-resolution
# failure), the raw log is printed instead, so a failure is never silent.
# Usage: run_filtered <log-name> <command...>
run_filtered() {
  local log_name=$1
  shift
  mkdir -p "$logs_dir"
  local raw_log="$logs_dir/$log_name.log"
  local filtered_log="$logs_dir/$log_name.toon"
  rm -f "$filtered_log"

  if [ "$use_xcsift" != true ] || ! command -v xcsift >/dev/null 2>&1; then
    local plain_status
    set +e
    "$@" 2>&1 | tee "$raw_log"
    plain_status=${PIPESTATUS[0]}
    set -e
    return "$plain_status"
  fi

  local statuses
  set +e
  # The compiler colors diagnostics (and links them with OSC 8) even into a pipe, and xcsift misses colored lines, so
  # its warning count, which the test gate reads, stayed 0. Strip escapes for xcsift; the raw log keeps them.
  "$@" 2>&1 | tee "$raw_log" | perl -pe 's/\e\[[0-9;]*[A-Za-z]//g; s/\e\]8;;.*?\e\\//g' | xcsift -f toon -w | tee "$filtered_log"
  statuses=("${PIPESTATUS[@]}")
  set -e

  local command_status=${statuses[0]}
  local pipeline_status=0
  local status
  for status in "${statuses[@]}"; do
    if [ "$status" -ne 0 ]; then
      pipeline_status=$status
      break
    fi
  done
  if [ "$pipeline_status" -eq 0 ]; then
    return 0
  fi

  if [ "$command_status" -ne 0 ] && [ ! -s "$filtered_log" ]; then
    echo "" >&2
    echo "$1 exited $command_status and xcsift produced no output - raw log ($raw_log):" >&2
    cat "$raw_log" >&2
  elif [ "$command_status" -eq 0 ]; then
    echo "" >&2
    echo "output formatting failed (statuses: ${statuses[*]}); raw log: $raw_log" >&2
  fi
  return "$pipeline_status"
}
