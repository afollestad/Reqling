<p align="center">
  <picture>
    <source srcset="docs/images/app-icon-dark.png" media="(prefers-color-scheme: dark)">
    <img src="docs/images/app-icon-light.png" alt="" width="96" height="96">
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

- [Projects](docs/projects.md): the project format, importing from Postman and OpenAPI, environments, variables, and iCloud sync
- [Requests](docs/requests.md): HTTP requests, responses, event streams, and run history
- [GraphQL](docs/graphql.md): schema-aware queries and the schema browser
- [gRPC](docs/grpc.md): calls, streams, and schema sources
- [WebSockets](docs/websockets.md): handshakes, messages, and timelines
- [Scripts](docs/scripts.md): pre-request, stream, and post-response JavaScript
- [Running folders and projects](docs/running-folders.md): every request in order, repeated or once per data row
- [MCP server](docs/mcp.md): letting AI agents work with your projects
- [TLS](docs/tls.md): client certificates and extra CAs
- [Updates](docs/updates.md): how Reqling checks, verifies, and installs updates

## Requirements

- A Mac with Apple silicon, on macOS 26 or later
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
| `./scripts/graphql-server.sh` | Serves a GraphQL schema on `127.0.0.1:4000` to try requests against |

Launch through `run.sh`, not `swift run` or Xcode, since only the bundle `build.sh` assembles has the Info.plist, assets, helpers, and signature. Builds run from `.build/` can check for updates but not install them.

## Architecture

| Path | Holds |
| --- | --- |
| `Sources/ReqlingKit` | Everything that isn't UI, from the project format and networking to the MCP server and iCloud sync, tested without the app |
| `Sources/Reqling` | The app: lifecycle, dependency injection through [Needle](https://github.com/uber/needle), view models, and views |
| `Sources/ReqlingTemplating` | `{{variable}}` parsing and expansion, Foundation only so helpers can share it |
| `Sources/ReqlingGraphQLEngine` | GraphQL SDL and validation from [GraphQLSwift](https://github.com/GraphQLSwift/GraphQL), kept in its own module |
| `Sources/ReqlingYAML` | YAML through [Yams](https://github.com/jpsim/Yams), kept in its own module |
| `Sources/ReqlingScriptProtocol` | What the app and the script runner exchange |
| `Sources/ReqlingScriptRunner` | A helper that runs request scripts in JavaScriptCore, with vendored crypto-js and lodash (MIT; licenses in `Runtime/vendor`) |
| `Sources/ReqlingPKCS12Probe` | A helper that opens each PKCS#12 file first, so a file that crashes Apple's importer can't take the app down |
| `Tools/GraphQLFixtureServer` | A separate package that executes a real schema, for the tests and `graphql-server.sh` |
| `Tests` | `ReqlingKitTests` and `ReqlingTests`, including snapshots |

HTTP goes through URLSession, and gRPC and WebSockets through [SwiftNIO](https://github.com/apple/swift-nio) and NIOSSL, which see every frame and share one TLS setup. Tests bind loopback ports and never touch your Keychain, Trash, or Application Support.

## Debug builds

Debug builds use `com.afollestad.reqling.debug` and appear as **Reqling Dev**, with their own preferences and data. They're signed with your Apple Development certificate when one is installed, so Keychain access survives rebuilds, and otherwise ad hoc. Reqling Dev syncs through CloudKit's Development environment only with a development provisioning profile that lists this Mac and your certificate, for an App ID with iCloud (container `iCloud.com.afollestad.reqling`) and Push Notifications; `scripts/build.sh` covers the overrides.

## Releases

CI builds, signs, notarizes, and publishes releases from `main`; [RELEASING.md](RELEASING.md) covers versioning, signing, and the publish gate.

## License

Reqling is licensed under the [GNU General Public License v3.0](LICENSE.md).
