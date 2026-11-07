## Scripting

These instructions cover `Sources/ReqlingKit/Scripting/`: running scripts through the helper, and the script API's catalog.

- **Run scripts only through a `ScriptRunning`** (`HelperScriptRunner` in the app), never in this process: the helper is what a time limit can kill. `ScriptSyntaxChecker` is the one JavaScriptCore use here, and it only parses.
- **Run a request's scripts only through the `ScriptSession` `RequestRunner` takes at the start of a run or preview.** It alone applies the helper's events, commits current values and cookie changes, and masks the report, so the window, history, and MCP all see the same masked result.
- **Set `RunOptions.mayPromptForTrust` only for runs the person started** (Send, re-run from history, and a folder or project run through `BatchRunner.begin(_:mayPromptForTrust:)`). An agent's run or a background fetch must never ask, so nothing but the person at the Mac grants a project's scripts trust.
- **Run a folder's or project's requests only through `BatchRunner`.** It asks about trust once for the whole run and carries `rq.variables` and the data row between steps (`RunOptions.batchStep`); a loop of bare `run` calls loses both.
- **Keep `ScriptAPICatalog` and `Sources/ReqlingScriptRunner/Runtime/` in step.** Every member a script can reach on `rq` and `pm` is listed with its phases and protocols; `ScriptRuntimeConformanceTests` fails on a member either side lacks.
- **Change the catalog, then rerun `ScriptAPIReferenceDocsTests` with `RECORD_SCRIPT_REFERENCE=1`.** `docs/scripts.md`'s API reference is generated from it, and the test fails while they differ.
