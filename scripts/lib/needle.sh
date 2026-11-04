# Needle DI code generation; source it after scripts/lib/common.sh.
#
# SwiftPM has no pre-build phase, so every entry point that compiles the app target (`build.sh`, `test.sh`) calls
# `generate_needle` first. The output is committed; never hand-edit it.

required_needle_version=0.25.1
needle_generated_file="$repo_root/Sources/Reqling/DI/Generated/NeedleGenerated.swift"

# The CLI must match the pinned NeedleFoundation package; a different generator can emit providers the runtime rejects.
require_needle() {
  if ! command -v needle >/dev/null 2>&1; then
    echo "error: needle $required_needle_version is required for DI code generation. Run ./scripts/setup.sh." >&2
    return 1
  fi
  local actual_version
  actual_version=$(needle version 2>/dev/null || true)
  if [ "$actual_version" != "$required_needle_version" ]; then
    echo "error: needle $required_needle_version is required to match the pinned NeedleFoundation package. Found: ${actual_version:-unknown}." >&2
    echo "Install that version, or update Package.swift and the generated DI output together." >&2
    return 1
  fi
}

# Generates into a staging file and copies it over only when the content differs: an unconditional write would move
# the file's mtime on every build and make SwiftPM recompile and relink the app for nothing.
generate_needle() {
  require_needle

  local stage_dir
  stage_dir=$(mktemp -d)
  local staged="$stage_dir/NeedleGenerated.swift"
  if ! SOURCEKIT_LOGGING=0 needle generate "$staged" "$repo_root/Sources/Reqling/DI" --exclude-paths "/DI/Generated" >&2; then
    rm -rf "$stage_dir"
    echo "error: needle generate failed." >&2
    return 1
  fi
  if [ ! -s "$staged" ]; then
    rm -rf "$stage_dir"
    echo "error: needle produced no output." >&2
    return 1
  fi
  # Needle omits the final newline.
  if [ -n "$(tail -c 1 "$staged")" ]; then
    echo >> "$staged"
  fi

  mkdir -p "$(dirname "$needle_generated_file")"
  if ! cmp -s "$staged" "$needle_generated_file"; then
    # `cat >` rather than `mv` so the destination keeps its own permissions.
    cat "$staged" > "$needle_generated_file"
    echo "Regenerated ${needle_generated_file#"$repo_root"/}"
  fi
  rm -rf "$stage_dir"
}
