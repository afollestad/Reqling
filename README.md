<p align="center">
  <picture>
    <source srcset="docs/images/app-icon-dark.png" media="(prefers-color-scheme: dark)">
    <img src="docs/images/app-icon-light.png" alt="" width="128" height="128">
  </picture>
</p>

<h1 align="center">Reqling</h1>

<p align="center">A minimal, fully native macOS client for HTTP, Server-Sent Events, WebSocket, GraphQL, and gRPC APIs, with a built-in MCP server for AI agents.</p>

<p align="center">
  <a href="https://github.com/afollestad/Reqling/releases/latest/download/Reqling.app.zip">
    <img src=".github/download-macos.svg?v=240x42" alt="Download Reqling for macOS (latest release)" width="240" height="42">
  </a>
</p>

Features and screenshots are at [reqling.af.codes](https://reqling.af.codes), and usage is in the [user guide](#user-guide). The rest of this README covers building and working on Reqling.

## User guide

- [Projects](docs/projects.md): the project format, environments, and variables
- [Requests](docs/requests.md): HTTP requests, responses, event streams, and run history
- [GraphQL](docs/graphql.md): schema-aware queries and the schema browser
- [gRPC](docs/grpc.md): calls, streams, and schema sources
- [WebSockets](docs/websockets.md): handshakes, messages, and timelines
- [MCP server](docs/mcp.md): letting AI agents work with your projects
- [TLS](docs/tls.md): client certificates and extra CAs
- [Updates](docs/updates.md): how Reqling checks, verifies, and installs updates

## Requirements

- macOS 26 or later
- Xcode 26 or later (Swift 6.2 or newer)
- Homebrew, for `xcsift`, SwiftLint, Needle, and protobuf

## Development

| Command | Does |
| --- | --- |
| `./scripts/setup.sh` | Installs tools, resolves packages, and installs the pre-commit hook |
| `./scripts/build.sh [--release]` | Builds `.build/app/<debug\|release>/Reqling.app` |
| `./scripts/run.sh [-b]` | (Re)launches the dev app; `-b` builds first |
| `./scripts/test.sh [filter ...]` | Runs the tests; filters are `swift test --filter` patterns |
| `./scripts/snapshots.sh <verify\|record>` | Verifies or re-records snapshot baselines |
| `./scripts/lint.sh [--fix]` | Runs SwiftLint; `--fix` autocorrects |
| `./scripts/screenshots.sh [-b]` | Captures the website's screenshots of a demo project, in light and dark |
| `./scripts/graphql-server.sh` | Serves a GraphQL schema on `127.0.0.1:4000` to try requests against; `--token` requires a bearer token, `--no-introspection` refuses introspection |
| `./scripts/generate-protos.sh` | Regenerates protobuf code and descriptor sets after a `.proto` change |

- **Launch through `run.sh`**, not `swift run` or Xcode. Reqling is a SwiftPM package, and only the `.app` bundle `build.sh` assembles has the Info.plist, the assets compiled with `actool`, `ReqlingPKCS12Probe`, and the signature.
- **Dependency injection** uses [Needle](https://github.com/uber/needle). The build and test scripts regenerate its providers before compiling, which is why `setup.sh` installs the matching `needle` CLI.
- **Updates.** Builds run from `.build/` can check for updates but not install them.

## Architecture

| Path | Holds |
| --- | --- |
| `Sources/ReqlingKit` | Everything that isn't UI: the project format, templating, HTTP, gRPC, WebSockets, GraphQL schemas, TLS, the request runner, and the MCP server. Tested without the app. |
| `Sources/Reqling` | The app: lifecycle, dependency injection, view models, and views |
| `Sources/ReqlingGraphQLEngine` | GraphQL SDL and validation from [GraphQLSwift](https://github.com/GraphQLSwift/GraphQL), the only module that imports it, since its declarations change how unrelated code type-checks |
| `Sources/ReqlingPKCS12Probe` | A helper that opens each PKCS#12 file first, so a file that crashes Apple's importer can't take the app down |
| `Tools/GraphQLFixtureServer` | A separate package that executes a real schema, for the tests and `graphql-server.sh` |
| `Tests` | `ReqlingKitTests` and `ReqlingTests`, including snapshots |

- **Networking.** HTTP goes through URLSession. gRPC and WebSockets go through [SwiftNIO](https://github.com/apple/swift-nio) and NIOSSL, which sees every WebSocket frame, server pings included, and shares one TLS setup with gRPC.
- **Tests run unattended.** Servers bind loopback on ephemeral ports, nothing touches your Keychain, Trash, or real Application Support, and TLS certificates and keys are minted per run, never committed.

## Debug builds

- **Separate identity.** Debug builds use `com.afollestad.reqling.debug` and appear as **Reqling Dev**, with their own preferences and Application Support folder, so they never touch a release build's data.
- **Signing.** They're signed with your Apple Development certificate when one is installed, so Keychain access survives rebuilds; otherwise they're signed ad hoc, and macOS asks again after each build. Set `DEBUG_CODESIGN_IDENTITY` to pick an identity, or `-` to force ad hoc.

## Releases

```sh
./scripts/build.sh --release
```

This builds a universal `.build/app/release/Reqling.app` with its dSYM beside it. Set `CODESIGN_IDENTITY` (for example `"Developer ID Application"`) to sign with the hardened runtime for distribution; otherwise it's signed ad hoc.

## License

Reqling is licensed under the [GNU General Public License v3.0](LICENSE.md).
