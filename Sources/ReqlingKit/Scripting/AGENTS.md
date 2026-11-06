## Scripting

These instructions cover `Sources/ReqlingKit/Scripting/`: running scripts through the helper, and the script API's catalog.

- **Launch scripts only through a `ScriptRunning`** (`HelperScriptRunner` in the app), never JavaScriptCore in this process: the helper is what a time limit can kill.
- **Keep `ScriptAPICatalog` and `Sources/ReqlingScriptRunner/Runtime/` in step.** Every member a script can reach on `rq` and `pm` is listed with its phases and protocols; `ScriptRuntimeConformanceTests` fails on a member either side lacks.
