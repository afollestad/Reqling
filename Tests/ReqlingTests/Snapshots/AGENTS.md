## Snapshot Tests

These instructions cover `Tests/ReqlingTests/Snapshots/` — `SnapshotTests` and its `+Topic` companions, the `assertMacSnapshot()` helper, and the baselines under `__Snapshots__/`. `Tests/AGENTS.md` owns test execution and the `+Topic` file convention this suite also follows.

**Keep a rule here only when the code that would violate it is not the code that documents it.** The helpers carry their own mechanism: `defaultPixelPrecision` holds the relaxed-precision defaults and why `1.0` is unreachable, `assertMacSnapshot` its window-backed render and off-screen determinism, `macSnapshotImage` renderer selection, and `snapshotCornerBackgroundPixel` the three-corner rule.

### Running

- **Use `./scripts/snapshots.sh`.** `record` runs with `RECORD_SNAPSHOTS=1` and then re-verifies; a record run alone proves nothing, because SnapshotTesting fails every test it records.
- **Record both appearances.** Every snapshot test captures a `light` and a `dark` baseline through `assertMacSnapshot(colorScheme:)`; a new surface adds both.
- **Audit for stale baselines by recording the full suite and diffing decoded pixels, not `git status`.** Decode drift marks most PNGs byte-changed, burying the few that actually moved.

### Calling The Helpers

- **Keep stored baselines at 2x, and never re-record one only because a non-Retina host captured it at 1x.** The fallback normalizes the 2x reference in memory; `REQLING_FORCE_FIXED_SCALE_SNAPSHOTS=true ./scripts/snapshots.sh verify` simulates such a host.
- **Fill fixture bitmaps with fixed, appearance-independent colors.** System colors are dynamic, so a dark-mode host bakes the dark variant into the bytes and a light-mode host disagrees over the whole image area.
- **A passing `verify` is not proof the baseline is current.** `precision: 0.99` budgets 1% of pixels and a changed label occupies far less, so `verify` passes with the old text still in the PNG. For an intentional visible change, `record` the affected baselines and eyeball the new images.

### Organizing Baselines

- Prefer focused `SnapshotTests+<Screen>.swift` companion files over growing `SnapshotTests.swift`; group coverage by screen or feature area.
- **Moving a snapshot test between files changes its baseline lookup path** under `__Snapshots__/`; move or re-record the reference images to match.
- **Snapshot lists unselected where the screen allows.** A `List`'s native selection highlight does not survive an offscreen capture and renders as a solid bar over the row, as in the Settings side list.
- **A prose-dense baseline reflows across macOS versions.** A newer macOS fits slightly more text per line, so a wrapped line at its break point moves and clears the tolerance; assert wording textually instead.
