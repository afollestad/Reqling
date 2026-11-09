## Release CI Scripts

These instructions cover the CI scripts under `scripts/ci/`; `RELEASING.md` documents the release process, the publish gate, and secrets. `scripts/AGENTS.md` covers developer scripts.

- **Keep YAML thin.** Put logic here and keep `.github/workflows/*.yml` as orchestration. Keep both workflows on the same runner label and `DEVELOPER_DIR`, so releases build on the validated toolchain.
- **Protect secrets.** Never print secret values, enable shell tracing, or write signing material outside `$RUNNER_TEMP`.
- **Keep the release's entitlements exactly `Config/Entitlements/Reqling.entitlements` plus the profile's identifiers.** `verify-release-app.sh` compares them whole, so an added entitlement, such as `get-task-allow`, fails the release until the template says so.
- **Fail before publishing.** Validate the version, tag, signatures, notarization, and packages before creating the tag or GitHub Release; only push-triggered `release` runs may do either.
- **Let `detect-release-version.py` own the mode**, including the `RELEASES_ENABLED` gate. Workflows only compare its outputs and never recompute them from `github.event_name` or the variable.
- **Read the bundle and dSYMs from `$EXPORT_PATH`.** Only `build-release-app.sh` sources `scripts/lib/common.sh`, so `.build/` layout stays with `scripts/build.sh`.
- **Ship a dSYM for every executable.** Release builds strip the app and each helper, and `create-dsym-zip.sh` fails on any executable in `Contents/MacOS` without a matching dSYM in `dsyms_path`.
- **Validate Copilot release notes structurally.** `generate-release-notes.sh` accepts only bold theme groups with linked italic children and one Full Changelog footer, and prints diagnostics on rejection.
- **Release assets feed the in-app updater.** Follow `Sources/ReqlingKit/Updates/AGENTS.md` before renaming, repackaging, or un-notarizing `Reqling.app.zip`.
- **Upload canaries from `stage-canary-app.sh`'s staging directory, never as a ZIP or the bundle path**, so a browser download expands straight to `Reqling.app`; `actions/upload-artifact` keeps file modes but drops the root folder and flattens symlinks.
- Cover script behavior with `*_tests.py`, run by `python3 -m unittest discover -s scripts/ci -p '*_tests.py'`. Keep Python compatible with 3.9 via `from __future__ import annotations`.
