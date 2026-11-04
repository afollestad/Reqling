<p align="center">
  <picture>
    <source srcset="docs/images/app-icon-dark.png" media="(prefers-color-scheme: dark)">
    <img src="docs/images/app-icon-light.png" alt="" width="128" height="128">
  </picture>
</p>

<h1 align="center">Reqling</h1>

<p align="center">A minimal, fully native macOS client for HTTP and gRPC APIs.</p>

Reqling is a SwiftUI app for creating, storing, organizing, and sending web requests, in the spirit of Postman but smaller and native to the Mac. It is in early development.

## Projects

A project is a folder of small JSON files, so it diffs cleanly and can live in your API's own git repository:

```
My API.reqling/
  project.json
  environments/default.json
  environments/staging.json
  requests/users/_folder.json
  requests/users/list-users.json
```

Create a project in Reqling's own folder, or choose a location such as a repository, then add folders and requests in the sidebar. **Add Project Folder…** opens one someone else shared. Renames move files rather than rewriting them, deletions go to the Trash, and edits made outside Reqling (a `git pull`, an editor) appear in the window as soon as they land. Filter the sidebar by name, method, or URL, and narrow it by method or by how each request's last run went.

## Environments and variables

Every project has a **Default** environment; add others (Staging, Production) to override its variables by key, and pick the active one from the toolbar. Reference a variable as `{{name}}` in the URL, parameters, headers, bodies, and auth. Built-ins such as `{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, and `{{$randomInt}}` generate a value on each send. Variables render as pills, red when undefined, and `{{` offers completion.

Mark a variable **secret** to keep its value in your Keychain instead of the project's files. Which environment is active, and anything else specific to your Mac, is never written into the project.

## Requests

- Any method, including custom ones such as `PURGE`. Methods that never carry a body (`GET`, `HEAD`, `TRACE`) keep the body you typed and send it again if you switch back.
- Bodies: **raw** with any Content-Type, **form-data**, **x-www-form-urlencoded**, **binary**, and **GraphQL** (a query and its variables, sent as the JSON body GraphQL servers expect).
- Auth: Basic, Bearer, and API key (header or query), set per request or inherited from a folder or the project.
- Automatic headers are listed alongside your own, including the ones macOS adds (`Host`, `Accept-Encoding`, `Accept-Language`). Add a header with the same name to replace one; switching off `User-Agent`, `Accept`, or `Content-Type` stops Reqling setting it, and macOS then sends its own default.
- Paste a cURL command into the URL field to import it, and **Copy as cURL** (⌥⌘C) to export the resolved request.
- Responses show status, timing per phase, headers, and the body: JSON is pretty-printed without reordering keys and highlighted, and images preview.
- ⌘F finds within the focused body or response.

## TLS and client certificates

A project's **Project Settings** take client certificates for mutual TLS — a PKCS#12 file (`.p12`/`.pfx`) or an identity already in your Keychain — matched by host (`api.example.com`, `*.internal`, `host:8443`), plus extra CA certificates trusted in addition to the system's. Passphrases are stored in your Keychain. For a `.crt` and `.key` pair, convert it first: `openssl pkcs12 -export -in client.crt -inkey client.key -out client.p12`.

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

`ReqlingKit` holds everything that is not UI — the project format, templating, HTTP, TLS, and the request runner — and is tested without the app. The tests are written to run unattended: servers bind loopback on ephemeral ports, and nothing touches your Keychain, Trash, or real Application Support. TLS certificates and keys are minted per run, never committed.

## Building a release

```sh
./scripts/build.sh --release
```

This produces a universal `.build/app/release/Reqling.app` with its dSYM beside it. Set `CODESIGN_IDENTITY` (for example `"Developer ID Application"`) to sign with the hardened runtime for distribution; otherwise the app is signed ad hoc.

## License

Reqling is licensed under the [GNU General Public License v3.0](LICENSE.md).
