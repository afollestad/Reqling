<p align="center">
  <picture>
    <source srcset="docs/images/app-icon-dark.png" media="(prefers-color-scheme: dark)">
    <img src="docs/images/app-icon-light.png" alt="" width="128" height="128">
  </picture>
</p>

<h1 align="center">Reqling</h1>

<p align="center">A minimal, fully native macOS client for HTTP, Server-Sent Events, GraphQL, and gRPC APIs, with a built-in MCP server for AI agents.</p>

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

Every project has its own **Default** environment; add others (Staging, Production) to override its variables by key, and pick the active one from the toolbar. The **Global** environment, at the top of every project's Environments sheet, holds variables every project shares; it is kept on your Mac, never in a project, and each project's environments override it by key. Reference a variable as `{{name}}` in the URL, parameters, headers, bodies, and auth. Built-ins such as `{{$uuid}}`, `{{$timestamp}}`, `{{$isoTimestamp}}`, and `{{$randomInt}}` generate a value on each send. Variables render as pills, red when undefined, and `{{` offers completion.

Mark a variable **secret** to keep its value in your Keychain instead of the project's files. Which environment is active, and anything else specific to your Mac, is never written into the project.

## Requests

- Any method, including custom ones such as `PURGE`. Methods that never carry a body (`GET`, `HEAD`, `TRACE`) keep the body you typed and send it again if you switch back.
- Bodies: **raw** with any Content-Type, **form-data**, **x-www-form-urlencoded**, **binary**, and **GraphQL** (a query and its variables, sent as the JSON body GraphQL servers expect; see [GraphQL](#graphql)).
- Auth: Basic, Bearer, and API key (header or query), set per request or inherited from a folder or the project.
- JSON editors and the GraphQL query editor indent as you press Return: a new line keeps the one above's indentation, goes a level deeper after `{` or `[`, and a bracket left open gets its closer on the line after, with the cursor between. A `}` or `]` typed at the start of a line moves back to its opener's indentation.
- Untick a parameter, header, form field, or variable to keep it but leave it out. Shift-click a checkbox to set every row between it and the last one you clicked, or use **Select All** and **Select None** above the rows.
- Automatic headers are listed alongside your own, including the ones macOS adds (`Host`, `Accept-Encoding`, `Accept-Language`). Add a header with the same name to replace one; switching off `User-Agent`, `Accept`, or `Content-Type` stops Reqling setting it, and macOS then sends its own default.
- Paste a cURL command into the URL field to import it, and **Copy as cURL** (⌥⌘C) to export the resolved request.
- Responses show status, timing per phase, headers, and the body. JSON and XML open as collapsible trees, with any value, key, or path a right-click away; Pretty re-indents JSON without reordering keys, and Raw shows the body as sent. Bodies of any size stay highlighted and scroll smoothly, and images preview.
- A response of type `text/event-stream` (Server-Sent Events) stays open and shows its events as they arrive, each with its type, ID, data, and arrival time, as a tree whose JSON data opens to its fields, or as text. A GET stream reconnects whenever it ends, after the server's `retry:` delay, sending `Last-Event-ID`; any other method, such as a POST to an LLM API, ends when the server closes it rather than running again. **Stop** (⌘.) ends a stream and keeps its events, and the request's timeout is how long one may stay silent.
- ⌘F finds within the focused body editor, and searches a response's text or tree in place; a timeline of messages or events is searchable in its Tree mode.
- Every run is kept in the request's history (**Request ▸ Show Run History**, ⌘Y, or the toolbar's inspector button): pick one to see its response again, re-run it, or restore its request into the editor, or select two and **Compare** them line by line, with JSON re-indented first so only real changes show. History stays on this Mac, never in the project; **Settings ▸ History** sets how long and how much is kept, and **Clear Run History…** in the sidebar's menus clears a request's or a project's.

## gRPC

Switch any request between HTTP and gRPC from the protocol menu in its header; its auth, headers, and host carry over. A gRPC request names a target (`host:port`, or `unix:/path` for a socket), a service, and a method, with messages written as proto3 JSON and `{{variables}}` anywhere in them. Unary, server-streaming, client-streaming, and bidirectional calls are all supported; a streaming call stays open so you can send more messages and end the stream yourself, and the response shows every message on a timeline, as a collapsible tree or as text, following the newest while you're scrolled to the end, with the initial metadata, trailers, and final status. A received message notes any fields the schema doesn't define, which usually means your protos are older than the server's.

The schema comes from one of three places:

- **Project protos.** In **Project Settings**, add the folders your `.proto` files live in (and, optionally, which files to compile). Folders inside the project's own folder or repository are stored relative to it, so the project works for everyone who clones it; anything else is remembered on this Mac only. Reqling compiles them with `protoc` and recompiles when they change. If `protoc` isn't installed, Reqling offers to install it, or uses one from Homebrew or your `PATH`.
- **Descriptor sets** (`.protoset`, `.binpb`), which need no `protoc`.
- **Server reflection**, for servers that expose it.

**Example** fills a message with every field of its type. Calls use the project's client certificates and CA certificates, the same as HTTP requests.

## GraphQL

A GraphQL body's query editor knows the API's schema. As you type, or on ⌃Space (or ⌥Esc) anywhere in the query, it completes what fits there: fields of the enclosing type, arguments, enum values, variables, directives, and fragments; it describes whatever the pointer rests on; and it underlines misspelled fields, missing required arguments, type mismatches, and deprecated usage, with a menu of the problems above the query. `{{variables}}` inside the query are left alone.

The schema comes from one of two places, chosen in the **Schema** row:

- **Introspection**, sent to the request's URL with its own headers, auth, and TLS settings as soon as the request opens, and cached on this Mac per endpoint, so the schema is there at once next time. The row says how old it is; reload to ask the server again.
- **A schema file**, for servers that turn introspection off: SDL (`.graphql`, `.graphqls`, `.gql`) or a saved introspection result (`.json`). A file inside the project's folder or repository is stored relative to it; for one elsewhere, Reqling asks whether to share its path or remember it on this Mac only.

**Request ▸ Show GraphQL Schema** (⌥⌘0) browses the schema in the inspector beside the request: the root types, then every type by kind, a filter over every type and field, and each type's fields, arguments, defaults, deprecations, and where it is used, with every type a click away. The toolbar's inspector button and **View ▸ Show Inspector** (⌥⌘I) show or hide the inspector without switching between History and Schema.

## MCP server

Reqling can run a local [MCP](https://modelcontextprotocol.io) server so AI agents on your Mac can work with your projects: create and edit projects, environments, variables, and saved requests, compile protos, read a GraphQL request's schema and check queries against it, send requests and read their responses (an event stream for a bounded time or number of events), and look back through each request's run history. Changes appear in the window as they happen. Turn it on in **Settings ▸ MCP**, which also shows the setup command for Claude Code and the config for Codex:

```sh
claude mcp add --transport http reqling http://127.0.0.1:39717/mcp --header "Authorization: Bearer <token>"
```

The server listens on `127.0.0.1` only and requires its bearer token, which is kept in your Keychain and can be regenerated. Secret values are write-only to agents: no tool returns one, and resolved requests and responses show them masked, even where a server echoes one back. Deletions go to the Trash.

## TLS and client certificates

A project's **Project Settings** take client certificates for mutual TLS — a PKCS#12 file (`.p12`/`.pfx`), a PEM certificate and private key (`.crt`/`.key`, RSA or EC, encrypted or not), or an identity already in your Keychain — matched by host (`api.example.com`, `*.internal`, `host:8443`), plus extra CA certificates trusted in addition to the system's. Passphrases are stored in your Keychain; certificates and keys are read in memory and never added to it.

macOS can't open a certificate whose EC key uses explicit curve parameters instead of a named curve; Reqling reports this instead of crashing. Reissue the certificate from a named-curve key; re-exporting the same certificate doesn't help.

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
./scripts/graphql-server.sh      # serve a GraphQL schema on 127.0.0.1:4000 to try GraphQL requests against
./scripts/lint.sh                # run SwiftLint (--fix to autocorrect)
./scripts/generate-protos.sh     # regenerate protobuf code and descriptor sets after changing a .proto
```

Reqling is a SwiftPM package; `scripts/build.sh` assembles the `.app` bundle, compiles its assets with `actool`, and bundles `ReqlingPKCS12Probe`, a helper that opens each PKCS#12 file first so a file that crashes Apple's importer can't take the app down. Launch it through `scripts/run.sh` rather than `swift run` or Xcode, since only the assembled bundle has its Info.plist, icon, and signature.

Debug builds use the `com.afollestad.reqling.debug` identity and appear as **Reqling Dev**. They keep their own preferences and Application Support folder, so they never touch a release build's data. They are signed with your Apple Development certificate when one is installed, so Keychain access survives rebuilds; without one they are signed ad hoc, and macOS asks again after each build. Set `DEBUG_CODESIGN_IDENTITY` to pick an identity, or `-` to force ad hoc.

Dependency injection uses [Needle](https://github.com/uber/needle). The build and test scripts regenerate its providers before compiling, which is why `setup.sh` installs the matching `needle` CLI.

`ReqlingKit` holds everything that is not UI — the project format, templating, HTTP, gRPC, GraphQL schemas, TLS, the request runner, and the MCP server — and is tested without the app. GraphQL SDL and validation come from [GraphQLSwift](https://github.com/GraphQLSwift/GraphQL), which only `ReqlingGraphQLEngine` imports: its declarations change how unrelated code type-checks in any module that can see them. The tests are written to run unattended: servers bind loopback on ephemeral ports, and nothing touches your Keychain, Trash, or real Application Support. GraphQL suites talk to `Tools/GraphQLFixtureServer`, a separate package that executes a real schema through GraphQLSwift; `scripts/graphql-server.sh` runs it by hand, optionally requiring a bearer token or refusing introspection. TLS certificates and keys are minted per run, never committed.

## Building a release

```sh
./scripts/build.sh --release
```

This produces a universal `.build/app/release/Reqling.app` with its dSYM beside it. Set `CODESIGN_IDENTITY` (for example `"Developer ID Application"`) to sign with the hardened runtime for distribution; otherwise the app is signed ad hoc.

## License

Reqling is licensed under the [GNU General Public License v3.0](LICENSE.md).
