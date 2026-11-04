<p align="center">
  <picture>
    <source srcset="docs/images/app-icon-dark.png" media="(prefers-color-scheme: dark)">
    <img src="docs/images/app-icon-light.png" alt="" width="128" height="128">
  </picture>
</p>

<h1 align="center">Reqling</h1>

<p align="center">A minimal, fully native macOS client for HTTP and gRPC APIs.</p>

Reqling is a SwiftUI app for creating, storing, organizing, and sending web requests, in the spirit of Postman but smaller and native to the Mac. It is in early development.

## Requirements

- macOS 26 or later
- Xcode 26 or later (Swift 6.2 or newer)
- Homebrew, for `xcsift`, SwiftLint, Needle, and protobuf

## Development

```sh
./scripts/setup.sh               # install tools, resolve packages, and install the pre-commit hook
./scripts/build.sh               # build .build/app/debug/Reqling.app
./scripts/run.sh -b              # build, then (re)launch the dev app
./scripts/test.sh [filter ...]   # run the tests; filters are `swift test --filter` patterns
./scripts/snapshots.sh verify    # verify snapshot baselines; `record` re-records them
./scripts/lint.sh                # run SwiftLint (--fix to autocorrect)
```

Reqling is a SwiftPM package; `scripts/build.sh` assembles the `.app` bundle and compiles its assets with `actool`. Launch it through `scripts/run.sh` rather than `swift run` or Xcode, since only the assembled bundle has its Info.plist, icon, and signature.

Debug builds use the `com.afollestad.reqling.debug` identity and appear as **Reqling Dev**. They keep their own preferences and Application Support folder, so they never touch a release build's data.

Dependency injection uses [Needle](https://github.com/uber/needle). The build and test scripts regenerate its providers before compiling, which is why `setup.sh` installs the matching `needle` CLI.

## Building a release

```sh
./scripts/build.sh --release
```

This produces a universal `.build/app/release/Reqling.app` with its dSYM beside it. Set `CODESIGN_IDENTITY` (for example `"Developer ID Application"`) to sign with the hardened runtime for distribution; otherwise the app is signed ad hoc.

## License

Reqling is licensed under the [GNU General Public License v3.0](LICENSE.md).
