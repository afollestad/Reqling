## Scripts

These instructions cover developer scripts under `scripts/`; `scripts/ci/AGENTS.md` covers the CI scripts the workflows run.

- Start every shell entry point with `#!/bin/bash` and `set -euo pipefail`, keep it executable, and source `scripts/lib/common.sh`, which sets `PATH`, moves to the repo root, and provides `app_path`, `dsyms_path`, and `run_filtered`.
- Keep `.app` bundle layout knowledge in `scripts/build.sh`; other scripts locate the bundle and release dSYMs through `app_path` and `dsyms_path`.
- Route every compiling `swift build` and `swift test` through `run_filtered`, so raw logs land in `.build/logs/` and xcsift's summary in the matching `.toon` file that `test.sh`'s warnings gate reads.
- Every entry point that compiles the app runs `generate_needle` (`scripts/lib/needle.sh`) first and applies `typecheck_budget_flags` (`scripts/lib/typecheck-budget.sh`); a differing flag set rebuilds the whole package graph.
- Expand possibly empty arrays as `${array[@]+"${array[@]}"}`; macOS's bash 3.2 treats a bare empty expansion as unbound under `set -u`.
- Keep honoring `CI=true` (setup skips the hooks); `.github/workflows/` run `setup.sh`, `lint.sh`, `build.sh`, and `test.sh` unchanged.
