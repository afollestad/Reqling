## Bundle Resources

These instructions cover the app bundle inputs under `Resources/`.

- These are not SwiftPM resources; `scripts/build.sh` copies `Info.plist` and compiles `Assets.xcassets` and `AppIcon.icon` with `actool`.
- `Info.plist` is the version source (`CFBundleShortVersionString`, `CFBundleVersion`). Read the running version from the bundle at runtime through `AppInfo`; never restate it. CI rejects a version that isn't `X.Y.Z` or a release whose build number doesn't increase (`RELEASING.md`).
- Release tags and the `Reqling.app.zip` asset follow the updater's release contract in `Sources/ReqlingKit/Updates/AGENTS.md`.
- Keep `CFBundleExecutable` equal to the SwiftPM executable product name in `Package.swift`.
- Leave icon keys out of `Info.plist`; `scripts/build.sh` merges them from actool's output.
- Keep the minimum macOS version in step across `LSMinimumSystemVersion`, the `Package.swift` platforms, and actool's `--minimum-deployment-target` in `scripts/build.sh`.
- Edit `AppIcon.icon` with Icon Composer. `AccentColor` is sampled from the icon's purple with a lighter dark variant; keep both in step with the icon.
