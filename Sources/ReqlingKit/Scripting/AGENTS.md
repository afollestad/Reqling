## Scripting

These instructions cover `Sources/ReqlingKit/Scripting/`: running scripts through the helper, and the script API's catalog.

- **Run scripts only through a `ScriptRunning`** (`HelperScriptRunner` in the app), never in this process: the helper is what a time limit can kill. `ScriptSyntaxChecker` is the one JavaScriptCore use here, and it only parses.
- **Run a request's scripts only through the `ScriptSession` `RequestRunner` takes at the start of a run or preview.** It alone applies the helper's events, commits current values and cookie changes, and masks the report, so the window, history, and MCP all see the same masked result.
- **Send scripts' requests only through `RequestRunner.performFetch`, each `ScriptSession`'s performer, never `run`.** A run would replace the named request's own run, land in its history, and run its scripts.
- **Never await scripts from a transport's `receive`.** Hand each event or message to `ScriptSession.deliver`, which returns at once; awaiting there stalls the stream and makes `LiveEventBuffer` drop what arrives.
- **Send `rq.send`'s messages only through `WebSocketLive.send(scripted:)` and `GRPCLiveCall.send(scriptedJSON:)`**, never the template-resolving `send`: scripts treat `{{name}}` as plain text.
- **Set `RunOptions.mayPromptForTrust` only for runs the person started** (Send, re-run from history, and a folder or project run through `BatchRunner.begin(_:mayPromptForTrust:)`). An agent's run or a background fetch must never ask, so nothing but the person at the Mac grants a project's scripts trust.
- **Anything that brings nodes into another project calls `ProjectLifecycle.revokeTrustIfUntrustedScriptsArrive`,** as `moveNode` does. Trust covers the scripts the person saw, so scripts arriving from a project this Mac never trusted must ask again.
- **Run a folder's or project's requests only through `BatchRunner`.** It asks about trust once for the whole run and carries `rq.variables` and the data row between steps (`RunOptions.batchStep`); a loop of bare `run` calls loses both.
- **Type a handler parameter as `.callback`, never `.function`.** Only a `.callback` argument types the parameters of the function a script passes (`ScriptExpressions.readParameters`) and gets called by `ScriptRuntimeConformanceTests`.
- **Type an options parameter as a named type of properties** (`OutgoingRequest`, `CookieOptions`), never `.object`. Only a named type completes and describes the keys of a literal passed there (`ScriptAnalyzer+Options.swift`).
- **List a script's problems only through `ScriptProblem.find`.** The editor, MCP's `scriptProblems`, and the Postman import all read it; a caller pairing `ScriptSyntaxChecker` with `ScriptAnalyzer.diagnostics()` itself drifts from what the others report.
- **Keep `ScriptAPICatalog` and `Sources/ReqlingScriptRunner/Runtime/` in step.** Every member a script can reach on `rq` and `pm` is listed with its phases and protocols; `ScriptRuntimeConformanceTests` fails on a member either side lacks.
- **Change the catalog, then rerun `ScriptAPIReferenceDocsTests` with `RECORD_SCRIPT_REFERENCE=1`.** `docs/scripts.md`'s API reference is generated from it, and the test fails while they differ.
