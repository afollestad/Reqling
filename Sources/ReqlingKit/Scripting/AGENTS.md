## Scripting

These instructions cover `Sources/ReqlingKit/Scripting/`: running scripts through the helper, and the script API's catalog.

- **Launch scripts only through a `ScriptRunning`** (`HelperScriptRunner` in the app), never JavaScriptCore in this process: the helper is what a time limit can kill.
- **Run a request's scripts only through the `ScriptSession` `RequestRunner` takes at the run's start.** It alone applies the helper's events, commits current values, and masks the report, so the window, history, and MCP all see the same masked result.
- **Set `RunOptions.mayPromptForTrust` only for runs the person started** (Send, re-run from history). An agent's run or a background fetch must never ask, so nothing but the person at the Mac grants a project's scripts trust.
- **Keep `ScriptAPICatalog` and `Sources/ReqlingScriptRunner/Runtime/` in step.** Every member a script can reach on `rq` and `pm` is listed with its phases and protocols; `ScriptRuntimeConformanceTests` fails on a member either side lacks.
