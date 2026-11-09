## Keep Guidance Current

- **`docs/` is the user guide, for humans.** Keep it to durable behavior and usage; put agent rules in `AGENTS.md`, and omit work tracking, validation histories, and commit hashes.
- Keep `AGENTS.md` accurate when changes create useful future-agent context; put new rules in the narrowest `AGENTS.md` that covers the affected files.
- **Default to not writing the bullet.** A rule belongs here only when the code that would violate it is not the code that documents it; mechanism whose only reader is its own file belongs in that file's doc comment instead.
    - Keep what the code cannot show: cross-file couplings, deliberate absences, and prohibitions against reintroducing removed behavior.
    - **The eviction has a destination.** A rule this test removes lands on the declaration that enforces it, in the same change — never only in a commit message.
- A bullet states one rule, imperatively. Cap rationale at one clause naming the failure mode; drop discovery narratives, rejected alternatives, and measurements unless the number itself is the constraint.
- One owner per rule. Cross-reference a rule that lives in another `AGENTS.md` instead of restating it, and when adding guidance, check whether existing guidance now duplicates or supersedes it.
- **Every path a bullet names must resolve.** Anchor a cross-scope reference at the repo root (`Sources/Reqling/Views/AGENTS.md`); anchor one inside this scope at this file's own folder. Never at a middle segment, and confirm the target exists.
    - Moving or renaming a scope means grepping its old path and repointing every inbound reference, doc comments included.
- Soft budget: ~40 words per bullet, ~1500 words per file. On breach, trim or split into sections rather than letting the file grow. Avoid file-listing maps in small folders; they rot silently.
- Categorize bullets with `##` sections when there are enough points; split dense rules into short sub-bullets with bold imperative leads.
- **Give a cohesive subsystem its own folder and `AGENTS.md` once trimming and sectioning stop being enough.** `git mv` its files together, write the nested file, and leave the parent one line naming what the child now owns.
    - Create the sibling symlink with `ln -s AGENTS.md CLAUDE.md`; that symlink is what loads the file into context.
    - Inside a SwiftPM target, add the folder to that target's `guidanceFiles(in:)` list in `Package.swift`; SwiftPM warns about both files otherwise.
- **Keep `README.md` for developers.** Update the README plus scoped guidance when dependencies, project structure, or lint rules change, and the matching `docs/` page when user-facing behavior changes.

## Scoped Guidance

Read the nearest `AGENTS.md` before editing; every scoped folder pairs it with a `CLAUDE.md` symlink that auto-loads it, and `find . -name AGENTS.md -not -path './.build/*'` lists them all.

## Swift Package

- `Package.swift` is the project; there is no Xcode project and no XcodeGen. Opening the package in Xcode is fine for editing, but launch through `./scripts/run.sh`: only the bundle `scripts/build.sh` assembles has the Info.plist, icon, and signing.
- `ReqlingKit` holds everything that is not UI and imports no SwiftUI. The `Reqling` executable holds the app lifecycle, DI, view models, and views.
- **Keep `ReqlingPKCS12Probe` to Foundation and Security**, so each launch stays fast. `scripts/build.sh` copies it into `Contents/MacOS`, where `Sources/Reqling/DI/AppComponent+Services.swift` finds it by name, as `Tests/ReqlingKitTests/Support/TLSFixtures.swift` does beside the test bundle; rename them together.
- **Keep `ReqlingScriptRunner` to Foundation, JavaScriptCore, CryptoKit, and `ReqlingScriptProtocol`**, for the same reason. It is found by name the same way, beside the app and beside the test bundle (`Tests/ReqlingKitTests/Support/ScriptFixtures.swift`); `Sources/ReqlingScriptRunner/AGENTS.md` covers its runtime folder.
- Pin dependencies exactly (`exact:` or `revision:`) and commit `Package.resolved`.
- After changing a pin, run `swift package resolve` and confirm `.build/checkouts/<dep>` moved to the new revision before trusting a green build.
- Never edit dependency sources under `.build/`; change the pin or the upstream package.
- **`Tools/GraphQLFixtureServer` is a separate package**, used only by `ReqlingKitTests` and `scripts/graphql-server.sh`, so `scripts/build.sh` never builds it. Keep the pins it shares with the root identical and commit its own `Package.resolved`; a mismatched exact pin fails the root's resolution.
- Debug builds are `com.afollestad.reqling.debug` ("Reqling Dev"). `scripts/build.sh` rewrites that identity and signs against `Config/CodeSigning/ReqlingDebugTCC.requirements`, and its provisioning profiles' App IDs name it, so change them together.

## Build And Test

- First-time setup: `./scripts/setup.sh`. It installs `xcsift`, `swiftlint`, `needle`, and `protobuf`, resolves packages, and installs the pre-commit hook.
- DI generation needs `needle 0.25.1`, matching the pinned NeedleFoundation; see `Sources/Reqling/DI/AGENTS.md`.
- Build: `./scripts/build.sh [--release]`. Run: `./scripts/run.sh [-b]`. Test: `./scripts/test.sh [filter ...]`. Snapshots: `./scripts/snapshots.sh <verify|record> [filter ...]`. Website screenshots: `./scripts/screenshots.sh [-b] [scene ...]`. GraphQL server to try against: `./scripts/graphql-server.sh [--token T] [--no-introspection]`.
- Run ordered workflows serially, never in parallel: build-then-run, build-then-test, record-then-verify.
- `.github/workflows/ci.yml` runs setup, lint, build, and test, with the type-check budgets below, on every PR and push to `main`; keep tests CI-safe (`Tests/AGENTS.md`).
- `.github/workflows/release.yml` builds signed canaries, notarized dry runs, and gated releases; read `RELEASING.md` and `scripts/ci/AGENTS.md` before changing versions, signing, or release packaging.
- `TYPECHECK_BUDGET_MS=3000 TYPECHECK_TEST_BUDGET_MS=7000` fails a build or test run when any function body or expression in this repo's sources exceeds that type-check time. `scripts/lib/typecheck-budget.sh` owns the mechanism and the exemption procedure.
    - A run only reports files it recompiled, so an incremental pass can miss an untouched offender; change the budget value or clean for the full picture.
    - Exempt a proven-noise path rather than raising the budget, and prove it is noise first, as that script describes.
- Add temporary logs early when useful; observe them yourself with `/usr/bin/log`, then remove them after confirming the fix.
- Never commit signing certificates, API keys, passwords, or base64 secret values.

### `xcsift` Output

- `build.sh`, `test.sh`, and `snapshots.sh` pipe through `xcsift -f toon -w` when it is installed (`--no-xcsift` for raw output); treat TOON `status` and the `summary` counts as the result. Raw logs stay in `.build/logs/`.
- **`test.sh` fails when the `warnings` count is non-zero.** Fix the cause; never loosen the gate.
- **`test.sh` holds the display awake with `caffeinate`.** AppKit animation and scrolling stall while the display sleeps, so a bare `swift test` on an idle machine can fail UI tests spuriously.
- Inspect TOON sections such as `errors[n]{file,line,message}`, `warnings[n]{file,line,message,type}`, `failed_tests`, and `linker_errors` when present; row headers name their own field order.

## Lint

- Lint: `./scripts/lint.sh` (pass `--fix` to autocorrect). Run SwiftLint from the repo root without `--config` so `Tests/.swiftlint.yml` applies.
- **Every lint violation is an error.** `.swiftlint.yml` sets `strict: true` for every SwiftLint run, and `lint.sh --fix` still fails on whatever autocorrection leaves. Never downgrade a rule to a warning; fix the code or narrow the rule's configuration.
- The pre-commit hook lints when staged files include Swift sources or `.swiftlint.yml`; `./scripts/setup.sh` installs it by setting `core.hooksPath=.githooks`.
- New Swift follows `.swiftlint.yml` (max line length 150, no force casts or force unwraps outside tests) plus a convention it does not encode: prefer `let`.
- If a change introduces lint warnings or errors, tell the user before committing.

## Code Style

- Put private types below public types.
- **Give a declaration a `///` doc comment when its contract is not obvious from its signature** — types, functions, and stored properties alike. Write the *why*: the failure mode it avoids, the ordering it depends on, the alternative that was rejected. Never restate what the body plainly does.
    - An `extension` that groups a subsystem takes a file-level `///` for what the whole group shares, so each member's own comment stays short.
    - A declaration whose rule used to live in an `AGENTS.md` needs this before that bullet may be deleted.
- Add concise inline comments only where they explain non-obvious intent at a specific line.
- Search for same-type companion files before editing behavior.
- Split large types into focused companions like `Type+Feature.swift`.
