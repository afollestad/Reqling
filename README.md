<p align="center">
  <picture>
    <source srcset="docs/images/app-icon-dark.png" media="(prefers-color-scheme: dark)">
    <img src="docs/images/app-icon-light.png" alt="" width="128" height="128">
  </picture>
</p>

<h1 align="center">Reqling</h1>

<p align="center">A minimal, fully native macOS client for HTTP and gRPC APIs, with a built-in MCP server for AI agents.</p>

<p align="center">
  <a href="https://github.com/afollestad/Reqling/releases/latest/download/Reqling.app.zip">
    <img src=".github/download-macos.svg?v=240x42" alt="Download Reqling for macOS (latest release)" width="240" height="42">
  </a>
</p>

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

Create a project in Reqling's own folder, or choose a location such as a repository, then add folders and requests in the sidebar. **Add Project Folder…** opens one someone else shared. Renames move files rather than rewriting them, deletions go to the Trash, and edits made outside Reqling (a `git pull`, an editor) appear in the window as soon as they land. Filter the sidebar by name, method, URL, or gRPC service, and narrow it by protocol, by method, or by how each request's last run went.

## Environments and variables

Every project has a **Default** environment; add others (Staging, Production) to override its variables by key, and pick the active one from the toolbar. Reference a variable as `{{name}}` in the URL, parameters, headers, bodies, and auth. Built-ins such as `{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, and `{{$randomInt}}` generate a value on each send. Variables render as pills, red when undefined, and `{{` offers completion.

Mark a variable **secret** to keep its value in your Keychain instead of the project's files. Which environment is active, and anything else specific to your Mac, is never written into the project.

## Requests

- Any method, including custom ones such as `PURGE`. Methods that never carry a body (`GET`, `HEAD`, `TRACE`) keep the body you typed and send it again if you switch back.
- Bodies: **raw** with any Content-Type, **form-data**, **x-www-form-urlencoded**, **binary**, and **GraphQL** (a query and its variables, sent as the JSON body GraphQL servers expect).
- Auth: Basic, Bearer, and API key (header or query), set per request or inherited from a folder or the project.
- Untick a parameter, header, form field, or variable to keep it but leave it out. Shift-click a checkbox to set every row between it and the last one you clicked, or use **Select All** and **Select None** above the rows.
- Automatic headers are listed alongside your own, including the ones macOS adds (`Host`, `Accept-Encoding`, `Accept-Language`). Add a header with the same name to replace one; switching off `User-Agent`, `Accept`, or `Content-Type` stops Reqling setting it, and macOS then sends its own default.
- Paste a cURL command into the URL field to import it, and **Copy as cURL** (⌥⌘C) to export the resolved request.
- Responses show status, timing per phase, headers, and the body. JSON and XML open as collapsible trees, with any value, key, or path a right-click away; Pretty re-indents JSON without reordering keys, and Raw shows the body as sent. Bodies of any size stay highlighted and scroll smoothly, and images preview.
- ⌘F finds within the focused body editor, and searches a response's text or tree in place.

## gRPC

Switch any request between HTTP and gRPC from the protocol menu in its header; its auth, headers, and host carry over. A gRPC request names a target (`host:port`, or `unix:/path` for a socket), a service, and a method, with messages written as proto3 JSON and `{{variables}}` anywhere in them. Unary, server-streaming, client-streaming, and bidirectional calls are all supported; a streaming call stays open so you can send more messages and end the stream yourself, and the response shows every message on a timeline, as a collapsible tree or as text, with the initial metadata, trailers, and final status. A received message notes any fields the schema doesn't define, which usually means your protos are older than the server's.

The schema comes from one of three places:

- **Project protos.** In **Project Settings**, add the folders your `.proto` files live in (and, optionally, which files to compile). Folders inside the project's own folder or repository are stored relative to it, so the project works for everyone who clones it; anything else is remembered on this Mac only. Reqling compiles them with `protoc` and recompiles when they change. If `protoc` isn't installed, Reqling offers to install it, or uses one from Homebrew or your `PATH`.
- **Descriptor sets** (`.protoset`, `.binpb`), which need no `protoc`.
- **Server reflection**, for servers that expose it.

**Example** fills a message with every field of its type. Calls use the project's client certificates and CA certificates, the same as HTTP requests.

## MCP server

Reqling can run a local [MCP](https://modelcontextprotocol.io) server so AI agents on your Mac can work with your projects: create and edit projects, environments, variables, and saved requests, compile protos, and send requests and read their responses. Changes appear in the window as they happen. Turn it on in **Settings ▸ MCP**, which also shows the setup command for Claude Code and the config for Codex:

```sh
claude mcp add --transport http reqling http://127.0.0.1:39717/mcp --header "Authorization: Bearer <token>"
```

The server listens on `127.0.0.1` only and requires its bearer token, which is kept in your Keychain and can be regenerated. Secret values are write-only to agents: no tool returns one, and resolved requests and responses show them masked, even where a server echoes one back. Deletions go to the Trash.

## TLS and client certificates

A project's **Project Settings** take client certificates for mutual TLS — a PKCS#12 file (`.p12`/`.pfx`), a PEM certificate and private key (`.crt`/`.key`, RSA or EC, encrypted or not), or an identity already in your Keychain — matched by host (`api.example.com`, `*.internal`, `host:8443`), plus extra CA certificates trusted in addition to the system's. Passphrases are stored in your Keychain; certificates and keys are read in memory and never added to it.

## Updates

Reqling checks this repository's GitHub Releases when it opens and every 6 hours (turn that off in **Settings ▸ App Updates**). The gear in the toolbar shows a dot when an update is available, and a green one once it's downloaded. Downloads are verified against GitHub's SHA-256 digest, then checked for the same bundle identifier, a newer version, a valid signature from the same developer, and Gatekeeper approval before **Install & Relaunch** replaces the app. A failed install restores the previous version. Builds run from `.build/` can check for updates but not install them.

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
./scripts/screenshots.sh -b      # capture the website's screenshots of a demo project, in light and dark
./scripts/lint.sh                # run SwiftLint (--fix to autocorrect)
./scripts/generate-protos.sh     # regenerate protobuf code and descriptor sets after changing a .proto
```

Reqling is a SwiftPM package; `scripts/build.sh` assembles the `.app` bundle and compiles its assets with `actool`. Launch it through `scripts/run.sh` rather than `swift run` or Xcode, since only the assembled bundle has its Info.plist, icon, and signature.

Debug builds use the `com.afollestad.reqling.debug` identity and appear as **Reqling Dev**. They keep their own preferences and Application Support folder, so they never touch a release build's data. They are signed with your Apple Development certificate when one is installed, so Keychain access survives rebuilds; without one they are signed ad hoc, and macOS asks again after each build. Set `DEBUG_CODESIGN_IDENTITY` to pick an identity, or `-` to force ad hoc.

Dependency injection uses [Needle](https://github.com/uber/needle). The build and test scripts regenerate its providers before compiling, which is why `setup.sh` installs the matching `needle` CLI.

`ReqlingKit` holds everything that is not UI — the project format, templating, HTTP, gRPC, TLS, the request runner, and the MCP server — and is tested without the app. The tests are written to run unattended: servers bind loopback on ephemeral ports, and nothing touches your Keychain, Trash, or real Application Support. TLS certificates and keys are minted per run, never committed.

## Building a release

```sh
./scripts/build.sh --release
```

This produces a universal `.build/app/release/Reqling.app` with its dSYM beside it. Set `CODESIGN_IDENTITY` (for example `"Developer ID Application"`) to sign with the hardened runtime for distribution; otherwise the app is signed ad hoc.

## License

Reqling is licensed under the [GNU General Public License v3.0](LICENSE.md).
