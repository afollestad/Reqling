## Needle And DI

These instructions apply to files under `Sources/Reqling/DI/` and `Sources/Reqling/DI/Generated/`.

- `Sources/Reqling/DI/Generated/NeedleGenerated.swift` is generated output (it carries no header saying so): keep it committed, never hand-edit it. `scripts/lib/needle.sh` regenerates it before every build and test run.
- Add Needle `Component` files under `Sources/Reqling/DI/`; the generator scans only this folder. Keep component declarations generator-visible, not `private`.
- `AppComponent` is the root component and owns app-scoped service instances through `shared { ... }`, grouped in `AppComponent+<Feature>.swift` extensions. Feature components are generator-visible scopes; do not introduce resolver containers or sibling-component lookups.
- **Derive every writable path from `AppStorageProfile`.** Tests build graphs with `AppDI.makeTestComponent(storageProfile: .test())`, which must never reach production Application Support, defaults, or the Keychain.
- Keep `AppStorageProfile.cleanUp()` refusing non-ephemeral profiles; a wipe of `.production` would erase the user's data.
