## Test Execution

These instructions apply to everything under `Tests/`. `Tests/ReqlingTests/Snapshots/AGENTS.md` owns the snapshot suite.

- `ReqlingKitTests` covers `ReqlingKit`; `ReqlingTests` covers the app target through `@testable import Reqling` — DI, view models, and snapshots.
- Run the smallest relevant scope you can, typically `./scripts/test.sh <filter>` with a `swift test --filter` pattern such as `ReqlingKitTests.AppInfoTests`.
- When updating UI, verify whether snapshot tests need to be updated and run the relevant snapshot checks before finishing.
- Do not assert exact SPM dependency revisions in tests; pins are configuration, and regressions should be covered by behavior-focused tests.
- **Never read a view's `@Environment` or `@FocusState` outside an installed body.** SwiftUI logs that as a runtime issue, which fails `test.sh`. Drive an unmounted view through a helper that takes the value as a parameter.
- **Avoid live `NSPopover` host tests on macOS 26.** Resizing a shown popover or opening nested shown popovers can crash a later test that pumps the run loop; prefer not-shown content and frame tests.

## CI-Safe Tests

There is no CI yet, but every test must be able to run unattended on a clean macOS runner.

- **No external network.** HTTP goes through `URLProtocol` stubs; local servers (HTTP, gRPC, MCP, fixtures) bind loopback port 0, never a fixed port. Checks against public servers belong in manual verification, never in a suite.
    - Serve GraphQL from `GraphQLFixtureServer`, which executes a real schema through GraphQLSwift; hand-written introspection JSON drifts from what servers send.
- **No developer or machine state.** Use `AppStorageProfile.test()`, always paired with its `cleanUp()`, instead of Application Support, a unique wiped `UserDefaults` suite instead of `.standard`, and in-memory secret stores instead of the Keychain.
    - Inject a trasher instead of calling `FileManager.trashItem`, which would fill the developer's real Trash.
    - Put `NSOpenPanel`, `NSWorkspace`, `NSApplication.terminate`, and process launches behind protocols.
- **External tools only where `scripts/setup.sh` guarantees them.** A test that needs `protoc` fails with "run ./scripts/setup.sh" when it is missing rather than skipping, so a misconfigured runner cannot pass silently. `codesign`, `spctl`, and `ditto` go through an injected command runner.
- **No wall-clock timing.** Debounces, schedules, and timeouts take an injected clock or sleep; async waits use bounded expectations, never `sleep`.
- **Deterministic and parallel-safe.** Inject IDs, dates, and random values such as multipart boundaries. Give each test unique temp directories and no shared mutable globals, so `swift test --parallel` stays safe.
- **Never commit TLS keys or certificates.** `TLSFixtures` mints the CA, client identity, and server leaves per test process, which also keeps server certificates under Apple's 825-day limit.

## Test Value

- Assert observable behavior or independent compatibility contracts; avoid checks that merely repeat implementation aliases or test-fixture behavior.
- Preserve distinct inputs, failures, and asynchronous checkpoints when consolidating overlapping tests.

## Test File Organization

When a test class grows large, split it into companion files named `<BaseTests>+<Topic>.swift`, such as `SnapshotTests+<Screen>.swift`.

- **Use an `extension <BaseTests>` in companion files**, not a new `final class`, so shared fixtures, helpers, and `setUp`/`tearDown` apply uniformly. Preserve the base class's actor annotation (for example `@MainActor`) on the extension.
- Only declare a separate `XCTestCase` subclass when the suite is genuinely independent; then name the file after the new class, without a `+`.
- Support files that define fixtures, stubs, or helper types (`*+Support.swift`, `*+Fixtures.swift`) are the exception — those declare separate helper types rather than extending the suite.
