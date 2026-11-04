## App Updates

These instructions cover the updater under `Sources/ReqlingKit/Updates/`: release lookup, download, staging, and the install helper. The declarations document their own mechanism (no-cache downloads, which releases contribute notes, staged-metadata cleanup, rollback).

- **Keep the release contract in step with whatever publishes releases.** Each stable GitHub Release is tagged `v` plus `Resources/Info.plist`'s `CFBundleShortVersionString` and carries `Reqling.app.zip` with `Reqling.app` at its top level; GitHub computes the asset digest the downloader verifies.
- **A release must be Developer ID–signed by the running app's team and pass Gatekeeper**, or the stager rejects it. Ad hoc and `.build/` builds can check but never install.
- **Releases stay public.** The release client is unauthenticated; never add a token or `gh` path that would put credentials in the app.
- **Installing quits Reqling, so only the user starts it** from the window (`Sources/Reqling/ViewModels/AppModel+Updates.swift`). MCP tools and automatic checks never install.
- Tests never reach GitHub or run `ditto`, `codesign`, or `spctl`: inject `URLProtocol` stubs and a `CommandRunning` stub, and an ephemeral DI graph gets an offline release client.
